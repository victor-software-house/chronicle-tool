import AVFoundation
import Foundation
import Testing
@testable import ChronicleCore

@Suite("PCMFloatConverter")
struct PCMFloatConverterTests {
  // MARK: - Buffer builders

  private static func float32Buffer(
    samples: [Float],
    sampleRate: Double = 16_000,
    channels: AVAudioChannelCount = 1
  ) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let dst = buffer.floatChannelData!.pointee
    for i in 0..<samples.count {
      dst[i] = samples[i]
    }
    return buffer
  }

  private static func int16Buffer(
    samples: [Int16],
    sampleRate: Double = 16_000,
    channels: AVAudioChannelCount = 1
  ) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let dst = buffer.int16ChannelData!.pointee
    for i in 0..<samples.count {
      dst[i] = samples[i]
    }
    return buffer
  }

  // MARK: - Tests

  @Test("fast Float32 path passes samples through unchanged")
  func float32FastPathPassesThrough() {
    let input: [Float] = [0.0, 0.25, -0.5, 0.99, -1.0]
    let buffer = Self.float32Buffer(samples: input)
    let converter = PCMFloatConverter(targetSampleRate: 16_000)
    let out = converter.convert(buffer)
    #expect(out != nil)
    #expect(out?.count == input.count)
    for (got, want) in zip(out!, input) {
      #expect(abs(got - want) < 1e-6)
    }
  }

  @Test("Int16 16 kHz mono fast path scales by 1/32768")
  func int16FastPathScalesCorrectly() {
    // 0 → 0, 16384 → 0.5, -16384 → -0.5, 32767 → 32767/32768 ≈ 0.99997
    let input: [Int16] = [0, 16384, -16384, 32767, -32768, 8192]
    let buffer = Self.int16Buffer(samples: input)
    let converter = PCMFloatConverter(targetSampleRate: 16_000)
    let out = converter.convert(buffer)
    #expect(out != nil)
    #expect(out?.count == input.count)
    let want: [Float] = input.map { Float($0) / 32_768.0 }
    for (got, w) in zip(out!, want) {
      #expect(abs(got - w) < 1e-6)
    }
  }

  @Test("Int16 fast path handles repeated buffers without state corruption")
  func int16FastPathRepeatedCalls() {
    let converter = PCMFloatConverter(targetSampleRate: 16_000)
    let inputs: [[Int16]] = [
      Array(repeating: Int16(1000), count: 800),
      Array(repeating: Int16(-2000), count: 800),
      Array(repeating: Int16(16384), count: 1600)
    ]
    var totalSamples = 0
    for input in inputs {
      let buffer = Self.int16Buffer(samples: input)
      let out = converter.convert(buffer)
      #expect(out != nil)
      #expect(out?.count == input.count)
      totalSamples += out!.count
      let expected = Float(input[0]) / 32_768.0
      for v in out! {
        #expect(abs(v - expected) < 1e-6)
      }
    }
    #expect(totalSamples == 3200)
  }

  @Test("empty buffer returns nil")
  func emptyBufferReturnsNil() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    buffer.frameLength = 0
    let converter = PCMFloatConverter(targetSampleRate: 16_000)
    #expect(converter.convert(buffer) == nil)
  }

  @Test("Float32 48 kHz mono input resamples to 16 kHz via AVAudioConverter slow path")
  func float32ResamplesViaSlowPath() {
    let inputSamples = (0..<480).map { _ in Float(0.1) }  // 10 ms at 48 kHz
    let buffer = Self.float32Buffer(samples: inputSamples, sampleRate: 48_000)
    let converter = PCMFloatConverter(targetSampleRate: 16_000)
    let out = converter.convert(buffer)
    #expect(out != nil)
    let count = out?.count ?? 0
    // 480 frames @ 48 kHz → ~160 frames @ 16 kHz (3:1 downsample).
    #expect(count >= 140 && count <= 200, "expected ~160 frames, got \(count)")
    // Constant-value input should yield (approximately) constant output.
    if let out, out.count > 8 {
      let middle = Array(out.dropFirst(4).dropLast(4))
      for v in middle {
        #expect(abs(v - 0.1) < 0.05, "resampled sample drifted: \(v)")
      }
    }
  }

  @Test("Int16 buffer at non-target rate falls through to slow path")
  func int16SlowPathResample() {
    // 1600 samples @ 48 kHz = ~33 ms. Expect ~530 samples @ 16 kHz.
    let input = (0..<1600).map { _ in Int16(8000) }
    let buffer = Self.int16Buffer(samples: input, sampleRate: 48_000)
    let converter = PCMFloatConverter(targetSampleRate: 16_000)
    let out = converter.convert(buffer)
    #expect(out != nil)
    let count = out?.count ?? 0
    #expect(count > 400 && count < 700, "expected ~533 frames, got \(count)")
  }
}
