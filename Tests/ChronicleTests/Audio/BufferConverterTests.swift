import AVFoundation
import Testing
@testable import Chronicle

@Suite("BufferConverter")
struct BufferConverterTests {
  @Test("converts interleaved Float32 stereo to Int16 mono when converter reports inputRanDry")
  func convertsInterleavedFloat32StereoToInt16Mono() throws {
    let sourceFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000,
      channels: 2,
      interleaved: true
    )!
    let destinationFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: true
    )!
    let converter = try #require(BufferConverter(from: sourceFormat, to: destinationFormat))
    let input = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4_800))
    input.frameLength = 4_800
    let samples = try #require(input.floatChannelData?[0])
    for frame in 0..<Int(input.frameLength) {
      let value = Float(frame % 64) / 64.0
      samples[frame * 2] = value
      samples[frame * 2 + 1] = value
    }

    let output = try #require(converter.convert(input))

    #expect(output.format.sampleRate == 16_000)
    #expect(output.format.channelCount == 1)
    #expect(output.format.commonFormat == .pcmFormatInt16)
    #expect(output.frameLength > 0)
    #expect(output.int16ChannelData != nil)
  }

  @Test("drains residual resampler frames after end of stream")
  func drainsResidualResamplerFramesAfterEndOfStream() throws {
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
    let input = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4_410))
    input.frameLength = 4_410
    let samples = try #require(input.floatChannelData?[0])
    for frame in 0..<Int(input.frameLength) {
      samples[frame] = Float(sin(Double(frame) * 0.01))
    }

    let output = try #require(converter.convert(input))
    let drained = converter.drain()
    let drainedFrames = drained.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }

    #expect(output.frameLength > 0)
    #expect(drainedFrames > 0)
    #expect(output.frameLength + drainedFrames >= 1_590)
    #expect(output.frameLength + drainedFrames <= 1_610)
    #expect(converter.drain().isEmpty)
    #expect(converter.convert(input) == nil)
  }
}
