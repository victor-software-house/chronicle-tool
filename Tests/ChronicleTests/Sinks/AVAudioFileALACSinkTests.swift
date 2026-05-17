import Testing
import Foundation
import AVFoundation
@testable import Chronicle

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

  @Test("makeAudioSidecarSink accepts ALAC and defaults to it")
  func factoryAcceptsALACAndDefaultsToIt() async throws {
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
    }

    let explicitCandidate = try makeAudioSidecarSink(
      path: explicitURL.path,
      analyzerFormat: format,
      audioFormat: "alac"
    )
    let explicit = try #require(explicitCandidate)
    #expect(explicit is AVAudioFileALACSink)
    await explicit.finish()

    let defaultCandidate = try makeAudioSidecarSink(
      path: defaultURL.path,
      analyzerFormat: format
    )
    let defaultSink = try #require(defaultCandidate)
    #expect(defaultSink is AVAudioFileALACSink)
    await defaultSink.finish()
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
