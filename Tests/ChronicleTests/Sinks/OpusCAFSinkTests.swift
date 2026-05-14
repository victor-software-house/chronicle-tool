import Testing
import Foundation
import AVFoundation
import AudioToolbox
@testable import Chronicle

@Suite("OpusCAFSink")
struct OpusCAFSinkTests {

  // MARK: - Helpers

  private func tmpURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("OpusCAFSinkTests.\(UUID().uuidString).\(name)")
  }

  private func makeSine(
    format: AVAudioFormat,
    seconds: Double,
    frequency: Double = 440.0,
    amplitude: Float = 0.2
  ) -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buf.frameLength = frameCount
    let sr = format.sampleRate
    if let ch = buf.floatChannelData?[0] {
      for i in 0..<Int(frameCount) {
        ch[i] = amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / sr))
      }
    } else if let ch = buf.int16ChannelData?[0] {
      for i in 0..<Int(frameCount) {
        let s = sin(2.0 * .pi * frequency * Double(i) / sr)
        ch[i] = Int16(amplitude * Float(s) * 32_000)
      }
    }
    return buf
  }

  private func probeWithAVAudioFile(_ url: URL) throws -> (frames: AVAudioFramePosition, fmt: AVAudioFormat) {
    let f = try AVAudioFile(forReading: url)
    return (f.length, f.processingFormat)
  }

  // MARK: - 1. Basic encode + readback

  @Test("encodes 5s of PCM and produces a readable CAF/Opus file")
  func encodesAndReadsBack() async throws {
    let url = tmpURL("basic.caf")
    defer { try? FileManager.default.removeItem(at: url) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let sink = try OpusCAFSink(url: url, sourceFormat: srcFmt, bitRate: 24_000)

    // Feed 5 seconds of audio in 100 ms chunks.
    let chunkSeconds: Double = 0.1
    let chunks = 50
    for _ in 0..<chunks {
      let buf = makeSine(format: srcFmt, seconds: chunkSeconds)
      await sink.append(buf)
    }
    await sink.finish()

    #expect(FileManager.default.fileExists(atPath: url.path))
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs[.size] as? Int) ?? 0
    #expect(size > 1000, "file should be at least 1 KB; got \(size) bytes")

    // File must be decodable. Frame count at 48 kHz (Opus internal rate)
    // should be close to 5 s = 240 000 frames; allow ±5 % for encoder
    // priming + tail framing.
    let (frames, fmt) = try probeWithAVAudioFile(url)
    let expectedFrames: Double = 240_000
    let ratio = Double(frames) / expectedFrames
    #expect(ratio > 0.95 && ratio < 1.05, "expected ~240 000 frames at 48 kHz, got \(frames) (ratio \(ratio))")
    #expect(fmt.sampleRate == 48_000)
    #expect(fmt.channelCount == 1)
  }

  // MARK: - 2. Bitrate is respected

  @Test("respects requested 24 kbps bitrate (file size within tolerance)")
  func respectsBitRate() async throws {
    let url = tmpURL("bitrate.caf")
    defer { try? FileManager.default.removeItem(at: url) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let sink = try OpusCAFSink(url: url, sourceFormat: srcFmt, bitRate: 24_000)

    let durationSeconds: Double = 10.0
    let buf = makeSine(format: srcFmt, seconds: durationSeconds)
    await sink.append(buf)
    await sink.finish()

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs[.size] as? Int) ?? 0
    // Expected audio bytes at 24 kbps over 10 s: 30 000. Plus CAF
    // container overhead (~30-40 KB). Reject anything above ~150 KB
    // (would imply >120 kbps).
    #expect(size > 15_000, "too small: \(size)")
    #expect(size < 150_000, "too large for 24 kbps over 10 s: \(size) bytes")
  }

  // MARK: - 3. Truncate-recovery (crash safety)

  @Test("file is readable even if not closed cleanly (truncate at midpoint)")
  func truncateRecovery() async throws {
    let url = tmpURL("truncate.caf")
    defer { try? FileManager.default.removeItem(at: url) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let sink = try OpusCAFSink(url: url, sourceFormat: srcFmt, bitRate: 24_000)

    // Write 10 seconds; finish to flush container info.
    let buf = makeSine(format: srcFmt, seconds: 10.0)
    await sink.append(buf)
    await sink.finish()

    let originalSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    #expect(originalSize > 0)

    // Simulate SIGKILL-style truncation: keep the first 60 % of the file
    // and verify it remains decodable. CAF stores its descriptor chunk
    // early; packet data is appended chunked; a clean truncation should
    // leave a valid-enough file for AVAudioFile to read prefix samples.
    let truncatedSize = originalSize * 60 / 100
    let handle = try FileHandle(forUpdating: url)
    try handle.truncate(atOffset: UInt64(truncatedSize))
    try handle.close()

    // Should still open. Frame count will be < original but > 0.
    let (frames, _) = try probeWithAVAudioFile(url)
    #expect(frames > 0, "truncated file should still yield some frames; got \(frames)")
  }

  // MARK: - 4. Per-buffer cadence doesn't error

  @Test("processes many small (10 ms) buffers without erroring")
  func smallBufferCadence() async throws {
    let url = tmpURL("cadence.caf")
    defer { try? FileManager.default.removeItem(at: url) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let sink = try OpusCAFSink(url: url, sourceFormat: srcFmt, bitRate: 24_000)

    // 2 seconds in 10 ms slices = 200 buffers, each 160 frames.
    let slice = 0.01
    for _ in 0..<200 {
      let buf = makeSine(format: srcFmt, seconds: slice)
      await sink.append(buf)
    }
    await sink.finish()

    let (frames, _) = try probeWithAVAudioFile(url)
    let expected: Double = 96_000  // 2 s at 48 kHz
    let ratio = Double(frames) / expected
    #expect(ratio > 0.9 && ratio < 1.1, "frame count out of range: \(frames) vs expected \(expected)")
  }
}
