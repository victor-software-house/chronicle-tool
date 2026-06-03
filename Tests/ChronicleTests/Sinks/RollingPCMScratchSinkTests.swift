import Testing
import Foundation
import AVFoundation
@testable import ChronicleCore

@Suite("RollingPCMScratchSink")
struct RollingPCMScratchSinkTests {

  // MARK: - Helpers

  private func tmpDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("RollingPCMScratchSinkTests.\(UUID().uuidString)")
  }

  private func makeBuffer(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    value: Float = 0.1
  ) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    if let ch = buf.floatChannelData?[0] {
      for i in 0..<Int(frames) { ch[i] = value }
    }
    return buf
  }

  private func makeStereoInt16Buffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 2,
      interleaved: false
    )!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    let left = buf.int16ChannelData![0]
    let right = buf.int16ChannelData![1]
    for i in 0..<Int(frames) {
      left[i] = Int16(1_000 + i)
      right[i] = Int16(-1_000 - i)
    }
    return buf
  }

  private func int16Values(from data: Data) -> [Int16] {
    data.withUnsafeBytes { rawBuffer in
      Array(rawBuffer.bindMemory(to: Int16.self))
    }
  }

  private func listSegments(_ dir: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "pcm" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  // MARK: - 1. Manifest + first segment created on init

  @Test("creates format.json manifest + first .pcm segment on init")
  func createsManifest() async throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let sink = try RollingPCMScratchSink(base: dir, sourceFormat: srcFmt, ttl: 60, rotateInterval: 30)

    let manifestURL = dir.appendingPathComponent("format.json")
    #expect(FileManager.default.fileExists(atPath: manifestURL.path))

    let data = try Data(contentsOf: manifestURL)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["sampleRate"] as? Double == 16_000)
    #expect(json?["channelCount"] as? Int == 1)
    #expect(json?["commonFormat"] as? String == "float32")
    #expect(json?["interleaved"] as? Bool == true)

    let segments = try listSegments(dir)
    #expect(segments.count == 1)
    #expect(segments[0].lastPathComponent == "000000.pcm")

    await sink.finish()
  }

  // MARK: - 2. Append writes bytes

  @Test("append() writes raw PCM bytes (Float32) to the current segment")
  func appendWritesBytes() async throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let sink = try RollingPCMScratchSink(base: dir, sourceFormat: srcFmt, ttl: 60, rotateInterval: 30)

    let frameCount: AVAudioFrameCount = 1600  // 100 ms at 16 kHz
    let buf = makeBuffer(format: srcFmt, frames: frameCount)
    await sink.append(buf)
    await sink.finish()

    let seg = dir.appendingPathComponent("000000.pcm")
    let bytes = try Data(contentsOf: seg)
    // 1600 frames * 1 channel * 4 bytes (Float32) = 6400 bytes
    #expect(bytes.count == 6400)
  }

  @Test("append() writes sample-exact interleaved Int16 scratch bytes")
  func appendWritesSampleExactInt16Scratch() async throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let buf = makeStereoInt16Buffer(frames: 4)
    let sink = try RollingPCMScratchSink(base: dir, sourceFormat: buf.format, ttl: 60, rotateInterval: 30)
    await sink.append(buf)
    await sink.finish()

    let manifestData = try Data(contentsOf: dir.appendingPathComponent("format.json"))
    let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    #expect(manifest?["sampleRate"] as? Double == 16_000)
    #expect(manifest?["channelCount"] as? Int == 2)
    #expect(manifest?["commonFormat"] as? String == "int16")
    #expect(manifest?["interleaved"] as? Bool == true)

    let bytes = try Data(contentsOf: dir.appendingPathComponent("000000.pcm"))
    #expect(bytes.count == 4 * 2 * MemoryLayout<Int16>.size)
    #expect(int16Values(from: bytes) == [
      1_000, -1_000,
      1_001, -1_001,
      1_002, -1_002,
      1_003, -1_003
    ])
  }

  // MARK: - 3. Rotation on interval

  @Test("rotates to a new segment after rotateInterval elapses")
  func rotatesOnInterval() async throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    // Very short rotateInterval so the test runs quickly. TTL well above
    // anything we'll hit so the first segment isn't pruned.
    let sink = try RollingPCMScratchSink(
      base: dir,
      sourceFormat: srcFmt,
      ttl: 60,
      rotateInterval: 0.1
    )

    let buf = makeBuffer(format: srcFmt, frames: 320)
    await sink.append(buf)
    try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms
    await sink.append(buf)  // triggers rotation
    try await Task.sleep(nanoseconds: 200_000_000)
    await sink.append(buf)  // triggers another rotation
    await sink.finish()

    let segments = try listSegments(dir)
    #expect(segments.count >= 2, "expected at least 2 segments after rotation; got \(segments.count)")
    #expect(segments.contains { $0.lastPathComponent == "000000.pcm" })
    #expect(segments.contains { $0.lastPathComponent == "000001.pcm" })
  }

  // MARK: - 4. TTL pruning

  @Test("prunes segments older than TTL on next rotation")
  func prunesOldSegments() async throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    // ttl 0.2s, rotateInterval 0.1s. After two rotations, the first
    // segment should age past TTL and be pruned.
    let sink = try RollingPCMScratchSink(
      base: dir,
      sourceFormat: srcFmt,
      ttl: 0.2,
      rotateInterval: 0.1
    )

    let buf = makeBuffer(format: srcFmt, frames: 320)
    // First segment created at init; write into it.
    await sink.append(buf)
    try await Task.sleep(nanoseconds: 150_000_000)  // 150 ms
    await sink.append(buf)  // rotation 1 (000001 starts)
    try await Task.sleep(nanoseconds: 250_000_000)  // 250 ms
    await sink.append(buf)  // rotation 2 (000002 starts; 000000 pruned)
    try await Task.sleep(nanoseconds: 150_000_000)
    await sink.append(buf)
    await sink.finish()

    let segments = try listSegments(dir)
    let names = segments.map { $0.lastPathComponent }
    #expect(!names.contains("000000.pcm"), "000000.pcm should have been pruned; segments: \(names)")
  }

  // MARK: - 5. Daemon restart picks up next segment index

  @Test("daemon restart resumes from highest existing segment index + 1")
  func resumesAfterRestart() async throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    // First lifecycle: create 3 segments.
    let s1 = try RollingPCMScratchSink(
      base: dir, sourceFormat: srcFmt, ttl: 60, rotateInterval: 0.05
    )
    let buf = makeBuffer(format: srcFmt, frames: 320)
    await s1.append(buf)
    try await Task.sleep(nanoseconds: 80_000_000)
    await s1.append(buf)
    try await Task.sleep(nanoseconds: 80_000_000)
    await s1.append(buf)
    await s1.finish()

    let beforeRestart = try listSegments(dir).map { $0.lastPathComponent }
    let highestBefore = beforeRestart.compactMap { Int($0.replacingOccurrences(of: ".pcm", with: "")) }.max() ?? -1

    // Restart: new sink in same dir should NOT clobber existing segments.
    let s2 = try RollingPCMScratchSink(
      base: dir, sourceFormat: srcFmt, ttl: 60, rotateInterval: 30
    )
    await s2.append(buf)
    await s2.finish()

    let afterRestart = try listSegments(dir).map { $0.lastPathComponent }
    let highestAfter = afterRestart.compactMap { Int($0.replacingOccurrences(of: ".pcm", with: "")) }.max() ?? -1
    #expect(highestAfter == highestBefore + 1,
            "expected new sink to start at \(highestBefore + 1); got highest=\(highestAfter) before=\(beforeRestart) after=\(afterRestart)")
  }
}
