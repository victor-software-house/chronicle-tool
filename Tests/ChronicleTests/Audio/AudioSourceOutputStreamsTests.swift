import AVFoundation
import Speech
import Testing
@testable import Chronicle

@Suite("AudioSource output streams")
struct AudioSourceOutputStreamsTests {
  @Test("yield sends same buffer to analyzer and PCM streams")
  func yieldSendsSameBufferToBothStreams() async throws {
    let streams = AudioSourceOutputStreams()
    let buffer = try #require(makeBuffer(sampleRate: 16_000, frames: 160))

    streams.yield(buffer)
    streams.finish()

    let analyzerCount = await countAnalyzerInputs(streams.analyzerInputs)
    let pcmBuffers = await collectPCMBufferRefs(streams.pcmBuffers)

    #expect(analyzerCount == 1)
    #expect(pcmBuffers.count == 1)
    #expect(pcmBuffers.first?.buffer === buffer)
  }

  @Test("yieldAll sends converter tail to both streams")
  func yieldAllSendsConverterTailToBothStreams() async throws {
    let sourceFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 44_100,
      channels: 1,
      interleaved: false
    )!
    let destinationFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let converter = try #require(BufferConverter(from: sourceFormat, to: destinationFormat))
    let input = try #require(makeBuffer(format: sourceFormat, frames: 4_410))
    let firstOutput = try #require(converter.convert(input))
    let streams = AudioSourceOutputStreams()

    streams.yield(firstOutput)
    streams.yieldAll(converter.drain())
    streams.finish()

    let analyzerCount = await countAnalyzerInputs(streams.analyzerInputs)
    let pcmBuffers = await collectPCMBufferRefs(streams.pcmBuffers)
    let totalPCMFrames = pcmBuffers.reduce(AVAudioFrameCount(0)) { $0 + $1.buffer.frameLength }

    #expect(analyzerCount == pcmBuffers.count)
    #expect(pcmBuffers.count >= 1)
    #expect(totalPCMFrames >= 1_590)
    #expect(totalPCMFrames <= 1_610)
  }

  private func makeBuffer(
    sampleRate: Double,
    frames: AVAudioFrameCount
  ) -> AVAudioPCMBuffer? {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    )!
    return makeBuffer(format: format, frames: frames)
  }

  private func makeBuffer(
    format: AVAudioFormat,
    frames: AVAudioFrameCount
  ) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      return nil
    }
    buffer.frameLength = frames
    guard let samples = buffer.floatChannelData?[0] else { return nil }
    for frame in 0..<Int(frames) {
      samples[frame] = Float(sin(Double(frame) * 0.01))
    }
    return buffer
  }

  private func countAnalyzerInputs(_ stream: AsyncStream<AnalyzerInput>) async -> Int {
    var count = 0
    for await _ in stream {
      count += 1
    }
    return count
  }

  private func collectPCMBufferRefs(_ stream: AsyncStream<PCMBufferRef>) async -> [PCMBufferRef] {
    var buffers: [PCMBufferRef] = []
    for await buffer in stream {
      buffers.append(buffer)
    }
    return buffers
  }
}
