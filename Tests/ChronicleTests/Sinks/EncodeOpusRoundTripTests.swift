import Testing
import Foundation
import AVFoundation
@testable import Chronicle

/// In-process round-trip: WAV-on-disk → `OpusCAFSink` → `AVAudioFile(forReading:)`.
///
/// Proves that the production sink writes a CAF container that AVFoundation can
/// reopen and stream-decode, which is the contract `chronicle transcribe` relies
/// on when consuming `OpusCAFSink` artefacts produced by `chronicle encode-opus`.
///
/// Companion to PRD-001 P11 verification (#50). The end-to-end WER parity check
/// against the 2026-05-13 reference lives in `scripts/verify-opus-parity.sh` and
/// is operator-run, not part of CI.
@Suite("EncodeOpus round-trip")
struct EncodeOpusRoundTripTests {

  private func tmpURL(_ suffix: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("EncodeOpus.\(UUID().uuidString).\(suffix)")
  }

  private func writeSineWAV(
    to url: URL,
    seconds: Double,
    sampleRate: Double = 16_000,
    frequency: Double = 440.0,
    amplitude: Float = 0.2
  ) throws -> AVAudioFormat {
    let fmt = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: true
    )!
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
    buf.frameLength = frameCount
    let data = buf.int16ChannelData![0]
    for i in 0..<Int(frameCount) {
      let s = sin(2.0 * .pi * frequency * Double(i) / sampleRate)
      data[i] = Int16(amplitude * Float(s) * 30_000)
    }
    let file = try AVAudioFile(
      forWriting: url,
      settings: fmt.settings,
      commonFormat: fmt.commonFormat,
      interleaved: fmt.isInterleaved
    )
    try file.write(from: buf)
    return fmt
  }

  @Test("AVAudioFile can read the Opus-in-CAF artefact end-to-end")
  func roundTripDecodesBack() async throws {
    let wavURL = tmpURL("input.wav")
    let cafURL = tmpURL("output.opus.caf")
    defer {
      try? FileManager.default.removeItem(at: wavURL)
      try? FileManager.default.removeItem(at: cafURL)
    }

    _ = try writeSineWAV(to: wavURL, seconds: 5.0)

    // Drive the production sink path the same way `chronicle encode-opus` does.
    let audioFile = try AVAudioFile(forReading: wavURL)
    let sink = try OpusCAFSink(
      url: cafURL,
      sourceFormat: audioFile.processingFormat,
      bitRate: OpusCAFSink.defaultBitRate
    )

    let chunkCapacity: AVAudioFrameCount = 4096
    while audioFile.framePosition < audioFile.length {
      let buf = AVAudioPCMBuffer(
        pcmFormat: audioFile.processingFormat,
        frameCapacity: chunkCapacity
      )!
      try audioFile.read(into: buf, frameCount: chunkCapacity)
      if buf.frameLength == 0 { break }
      await sink.append(buf)
    }
    await sink.finish()

    // Reopen the sink artefact as an AVAudioFile.
    let opusReader = try AVAudioFile(forReading: cafURL)

    // File format must announce Opus.
    let fileASBD = opusReader.fileFormat.streamDescription.pointee
    #expect(fileASBD.mFormatID == kAudioFormatOpus,
            "fileFormat should be Opus; got \(fileASBD.mFormatID)")

    // Processing format is Apple's canonical decode target: 48 kHz Float32.
    let procFormat = opusReader.processingFormat
    #expect(procFormat.sampleRate == 48_000,
            "decoded SR should be 48000; got \(procFormat.sampleRate)")
    #expect(procFormat.channelCount == 1,
            "channel count should be 1; got \(procFormat.channelCount)")

    // Decoded length should be ≈ 5 s at 48 kHz (allow small Opus look-ahead delta).
    let durationSeconds = Double(opusReader.length) / procFormat.sampleRate
    #expect(abs(durationSeconds - 5.0) <= 0.1,
            "expected ≈ 5 s decoded; got \(durationSeconds) s")

    // Stream the decoded PCM end-to-end without throwing.
    var framesRead: AVAudioFramePosition = 0
    while opusReader.framePosition < opusReader.length {
      let outBuf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: 4096)!
      try opusReader.read(into: outBuf, frameCount: 4096)
      if outBuf.frameLength == 0 { break }
      framesRead += AVAudioFramePosition(outBuf.frameLength)
    }
    #expect(framesRead == opusReader.length,
            "expected to drain all decoded frames; read \(framesRead)/\(opusReader.length)")
  }
}
