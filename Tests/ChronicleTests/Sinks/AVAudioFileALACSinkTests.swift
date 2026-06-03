import Testing
import Foundation
import AVFoundation
@testable import Chronicle
@testable import ChronicleCore

@Suite("AVAudioFile ALAC sink")
struct AVAudioFileALACSinkTests {

  private func tmpURL(_ suffix: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AVAudioFileALACSink.\(UUID().uuidString).\(suffix)")
  }

  private func writeSineWAV(
    to url: URL,
    seconds: Double,
    sampleRate: Double = 16_000,
    frequency: Double = 440.0,
    amplitude: Float = 0.2
  ) throws {
    let fmt = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    )!
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
    buf.frameLength = frameCount
    let data = buf.floatChannelData![0]
    for i in 0..<Int(frameCount) {
      let s = sin(2.0 * .pi * frequency * Double(i) / sampleRate)
      data[i] = amplitude * Float(s)
    }
    let file = try AVAudioFile(
      forWriting: url,
      settings: fmt.settings,
      commonFormat: fmt.commonFormat,
      interleaved: fmt.isInterleaved
    )
    try file.write(from: buf)
  }

  private func sineBuffer(
    seconds: Double,
    sampleRate: Double = 16_000,
    frequency: Double = 440.0,
    amplitude: Float = 0.2
  ) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    )!
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
    buf.frameLength = frameCount
    let data = buf.floatChannelData![0]
    for i in 0..<Int(frameCount) {
      let s = sin(2.0 * .pi * frequency * Double(i) / sampleRate)
      data[i] = amplitude * Float(s)
    }
    return buf
  }

  private func int16PatternBuffer(
    frames: AVAudioFrameCount,
    sampleRate: Double = 16_000,
    start: Int
  ) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    )!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    let data = buf.int16ChannelData![0]
    for i in 0..<Int(frames) {
      data[i] = Int16(((start + i) % 32_000) - 16_000)
    }
    return buf
  }

  private func decodedInt16Bytes(from url: URL) throws -> Data {
    let file = try AVAudioFile(
      forReading: url,
      commonFormat: .pcmFormatInt16,
      interleaved: false
    )
    var out = Data()
    while file.framePosition < file.length {
      let frameCount = min(4096, AVAudioFrameCount(file.length - file.framePosition))
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
      try file.read(into: buffer, frameCount: frameCount)
      guard buffer.frameLength > 0, let channel = buffer.int16ChannelData?[0] else { break }
      out.append(Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size))
    }
    return out
  }

  private func scratchURL(for sidecarURL: URL) -> URL {
    sidecarURL
      .deletingLastPathComponent()
      .appendingPathComponent("scratch", isDirectory: true)
      .appendingPathComponent(sidecarURL.deletingPathExtension().lastPathComponent, isDirectory: true)
  }

  @Test("makeAudioSidecarSink accepts ALAC and defaults to composite ALAC plus scratch")
  func factoryAcceptsALACAndDefaultsToCompositeScratch() async throws {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let explicitURL = tmpURL("explicit.alac.caf")
    let defaultURL = tmpURL("default.alac.caf")
    defer {
      try? FileManager.default.removeItem(at: explicitURL)
      try? FileManager.default.removeItem(at: defaultURL)
      try? FileManager.default.removeItem(at: scratchURL(for: explicitURL))
      try? FileManager.default.removeItem(at: scratchURL(for: defaultURL))
    }

    let explicitCandidate = try makeAudioSidecarSink(
      path: explicitURL.path,
      analyzerFormat: format,
      audioFormat: "alac",
      rotateAudio: 0
    )
    let explicit = try #require(explicitCandidate)
    #expect(explicit is CompositeAudioSidecarSink)
    await explicit.append(sineBuffer(seconds: 0.1))
    await explicit.finish()
    #expect(FileManager.default.fileExists(atPath: explicitURL.path))
    #expect(FileManager.default.fileExists(atPath: scratchURL(for: explicitURL).appendingPathComponent("format.json").path))

    let defaultCandidate = try makeAudioSidecarSink(
      path: defaultURL.path,
      analyzerFormat: format,
      rotateAudio: 0
    )
    let defaultSink = try #require(defaultCandidate)
    #expect(defaultSink is CompositeAudioSidecarSink)
    await defaultSink.append(sineBuffer(seconds: 0.1))
    await defaultSink.finish()
    #expect(FileManager.default.fileExists(atPath: defaultURL.path))
    #expect(FileManager.default.fileExists(atPath: scratchURL(for: defaultURL).appendingPathComponent("format.json").path))
  }

  @Test("rotating ALAC sidecar writes numbered CAF segments")
  func rotatingALACWritesNumberedSegments() async throws {
    let baseURL = tmpURL("rotating.alac.caf")
    let firstURL = RotatingAudioSidecarSink.segmentURL(for: baseURL, index: 1)
    let secondURL = RotatingAudioSidecarSink.segmentURL(for: baseURL, index: 2)
    defer {
      try? FileManager.default.removeItem(at: baseURL)
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
      try? FileManager.default.removeItem(at: scratchURL(for: baseURL))
    }

    let buf = sineBuffer(seconds: 0.2)
    let candidate = try makeAudioSidecarSink(
      path: baseURL.path,
      analyzerFormat: buf.format,
      audioFormat: "alac",
      rotateAudio: 0.1
    )
    let sink = try #require(candidate)
    await sink.append(buf)
    await sink.append(buf)
    await sink.finish()

    #expect(!FileManager.default.fileExists(atPath: baseURL.path))
    #expect(FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: secondURL.path))
    #expect(FileManager.default.fileExists(atPath: scratchURL(for: baseURL).appendingPathComponent("format.json").path))

    let firstReader = try AVAudioFile(forReading: firstURL)
    let secondReader = try AVAudioFile(forReading: secondURL)
    #expect(firstReader.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
    #expect(secondReader.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
  }

  @Test("rotated ALAC segments decode to the same PCM as one continuous ALAC file")
  func rotatedALACSegmentsPreservePCMContinuity() async throws {
    let continuousURL = tmpURL("continuous.alac.caf")
    let rotatedBaseURL = tmpURL("continuity.alac.caf")
    let firstURL = RotatingAudioSidecarSink.segmentURL(for: rotatedBaseURL, index: 1)
    let secondURL = RotatingAudioSidecarSink.segmentURL(for: rotatedBaseURL, index: 2)
    let thirdURL = RotatingAudioSidecarSink.segmentURL(for: rotatedBaseURL, index: 3)
    defer {
      try? FileManager.default.removeItem(at: continuousURL)
      try? FileManager.default.removeItem(at: rotatedBaseURL)
      try? FileManager.default.removeItem(at: firstURL)
      try? FileManager.default.removeItem(at: secondURL)
      try? FileManager.default.removeItem(at: thirdURL)
    }

    let buffers = (0..<6).map { int16PatternBuffer(frames: 640, start: $0 * 640) } // 40 ms each @ 16 kHz.
    let sourceFormat = buffers[0].format

    let continuous = try AVAudioFileALACSink(url: continuousURL, sourceFormat: sourceFormat)
    for buffer in buffers {
      await continuous.append(buffer)
    }
    await continuous.finish()

    let rotating = try RotatingAudioSidecarSink(
      baseURL: rotatedBaseURL,
      rotateInterval: 0.08,
      sourceFormat: sourceFormat
    ) { segmentURL in
      try AVAudioFileALACSink(url: segmentURL, sourceFormat: sourceFormat)
    }
    for buffer in buffers {
      await rotating.append(buffer)
    }
    await rotating.finish()

    let expected = try decodedInt16Bytes(from: continuousURL)
    var actual = Data()
    for url in [firstURL, secondURL, thirdURL] where FileManager.default.fileExists(atPath: url.path) {
      actual.append(try decodedInt16Bytes(from: url))
    }

    #expect(FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: secondURL.path))
    #expect(actual.count == expected.count, "rotated decoded bytes \(actual.count) != continuous decoded bytes \(expected.count)")
    #expect(actual == expected)
  }

  @Test("AVAudioFile writes ALAC-in-CAF that AVFoundation reopens")
  func writesReadableALACCAF() async throws {
    let wavURL = tmpURL("input.wav")
    let cafURL = tmpURL("output.alac.caf")
    defer {
      try? FileManager.default.removeItem(at: wavURL)
      try? FileManager.default.removeItem(at: cafURL)
    }

    try writeSineWAV(to: wavURL, seconds: 5.0)

    let audioFile = try AVAudioFile(forReading: wavURL)
    let sink = try AVAudioFileALACSink(
      url: cafURL,
      sourceFormat: audioFile.processingFormat
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

    let alacReader = try AVAudioFile(forReading: cafURL)
    let fileASBD = alacReader.fileFormat.streamDescription.pointee
    #expect(fileASBD.mFormatID == kAudioFormatAppleLossless,
            "fileFormat should be ALAC; got \(fileASBD.mFormatID)")
    #expect(alacReader.fileFormat.channelCount == 1,
            "channel count should be 1; got \(alacReader.fileFormat.channelCount)")
    #expect(alacReader.fileFormat.sampleRate == 16_000,
            "sample rate should be 16000; got \(alacReader.fileFormat.sampleRate)")

    let procFormat = alacReader.processingFormat
    let durationSeconds = Double(alacReader.length) / procFormat.sampleRate
    #expect(abs(durationSeconds - 5.0) <= 0.05,
            "expected ≈ 5 s decoded; got \(durationSeconds) s")

    var framesRead: AVAudioFramePosition = 0
    while alacReader.framePosition < alacReader.length {
      let outBuf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: 4096)!
      try alacReader.read(into: outBuf, frameCount: 4096)
      if outBuf.frameLength == 0 { break }
      framesRead += AVAudioFramePosition(outBuf.frameLength)
    }
    #expect(framesRead == alacReader.length,
            "expected to drain all decoded frames; read \(framesRead)/\(alacReader.length)")
  }
}
