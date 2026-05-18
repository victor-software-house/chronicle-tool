import AVFoundation
import Foundation

/// Converts an `AVAudioPCMBuffer` (in any supported format) to a flat
/// `[Float]` array at a fixed target sample rate and mono channel layout.
///
/// Three paths:
///
/// 1. **Fast Float32 path** — input is already `pcmFormatFloat32`, mono, and
///    at the target rate. Returns a copy of the existing channel data.
/// 2. **Fast Int16 path** — input is `pcmFormatInt16`, mono, at the target
///    rate. Performs a manual `Float(sample) / 32_768.0` scale. This is the
///    hot path for the live mic / sysaudio pipeline because both sources
///    deliver 16 kHz mono Int16 buffers (matching SpeechAnalyzer's
///    `bestAvailableAudioFormat`). It exists because the generic
///    `AVAudioConverter` callback path proved brittle for back-to-back
///    same-rate format conversions in the live pipeline.
/// 3. **Slow `AVAudioConverter` path** — any other input format. Builds (and
///    caches) an `AVAudioConverter` lazily and runs a one-shot conversion
///    per input buffer.
///
/// The class is thread-`@unchecked Sendable` because `AVAudioConverter` is
/// not thread-safe; callers must serialize `convert(_:)` invocations.
public final class PCMFloatConverter: @unchecked Sendable {
  public let targetSampleRate: Double
  private(set) public var lastErrorDescription: String?

  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var converterOutputFormat: AVAudioFormat?

  public init(targetSampleRate: Double = 16_000) {
    self.targetSampleRate = targetSampleRate
  }

  /// Convert `buffer` to a `[Float]` array at `targetSampleRate`, mono.
  /// Returns `nil` for empty or unconvertible buffers; in the error case
  /// `lastErrorDescription` is populated for diagnostics.
  public func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return nil }
    let inputFormat = buffer.format

    // Fast path 1: already mono Float32 at the target rate.
    if inputFormat.sampleRate == targetSampleRate,
       inputFormat.commonFormat == .pcmFormatFloat32,
       inputFormat.channelCount == 1,
       let ptr = buffer.floatChannelData?.pointee {
      return Array(UnsafeBufferPointer(start: ptr, count: frameCount))
    }

    // Fast path 2: mono Int16 at the target rate. Hot path for the live
    // mic / sysaudio sources which deliver SpeechAnalyzer's preferred
    // format (16 kHz mono Int16) directly.
    if inputFormat.sampleRate == targetSampleRate,
       inputFormat.commonFormat == .pcmFormatInt16,
       inputFormat.channelCount == 1,
       let int16Ptr = buffer.int16ChannelData?.pointee {
      var floats = [Float](repeating: 0, count: frameCount)
      let scale: Float = 1.0 / 32_768.0
      for i in 0..<frameCount {
        floats[i] = Float(int16Ptr[i]) * scale
      }
      return floats
    }

    // Slow path: AVAudioConverter for everything else.
    let outFormat: AVAudioFormat
    if let cached = converterOutputFormat, converter != nil,
       inputFormat == converterInputFormat {
      outFormat = cached
    } else {
      guard let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      ) else {
        lastErrorDescription = "Could not build \(targetSampleRate) Hz mono float format"
        return nil
      }
      guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
        lastErrorDescription = "Could not build AVAudioConverter \(inputFormat) -> \(target)"
        return nil
      }
      self.converter = conv
      self.converterInputFormat = inputFormat
      self.converterOutputFormat = target
      outFormat = target
    }

    let inputFrames = Double(buffer.frameLength)
    let ratio = outFormat.sampleRate / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 64
    guard let outBuffer = AVAudioPCMBuffer(
      pcmFormat: outFormat,
      frameCapacity: outputCapacity
    ) else { return nil }

    final class ConvertState { var consumed = false }
    let state = ConvertState()
    nonisolated(unsafe) let captureBuffer = buffer
    var error: NSError?
    let status = converter!.convert(to: outBuffer, error: &error) { _, outStatus in
      if state.consumed {
        outStatus.pointee = .endOfStream
        return nil
      }
      state.consumed = true
      outStatus.pointee = .haveData
      return captureBuffer
    }
    if status == .error || error != nil {
      lastErrorDescription = error?.localizedDescription ?? "AVAudioConverter status=\(status.rawValue)"
      return nil
    }
    let outCount = Int(outBuffer.frameLength)
    guard outCount > 0, let outPtr = outBuffer.floatChannelData?.pointee else {
      return nil
    }
    return Array(UnsafeBufferPointer(start: outPtr, count: outCount))
  }
}
