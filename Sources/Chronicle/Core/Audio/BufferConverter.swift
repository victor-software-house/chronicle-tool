import AVFoundation
import Foundation

/// Lock-free `AVAudioConverter` wrapper that converts buffers from one format
/// to another inside an audio-thread callback.
///
/// `AVAudioConverter` is *not* thread-safe; callers must hold one instance per
/// converter chain. This wrapper exists so an `installTap` callback can stash
/// a `BufferConverter` and call `convert(_:)` synchronously without allocating
/// or capturing scope on every invocation.
public final class BufferConverter: @unchecked Sendable {
  public let sourceFormat: AVAudioFormat
  public let destinationFormat: AVAudioFormat
  private static let resamplerTailHeadroomFrames = AVAudioFrameCount(64)
  private static let drainOutputCapacity = AVAudioFrameCount(4096)
  private static let maxDrainIterations = 16

  private let converter: AVAudioConverter

  public init?(from source: AVAudioFormat, to destination: AVAudioFormat) {
    guard let conv = AVAudioConverter(from: source, to: destination) else { return nil }
    self.sourceFormat = source
    self.destinationFormat = destination
    self.converter = conv
  }

  /// Convert `input` to `destinationFormat`. Returns `nil` on conversion error
  /// or zero-frame output. Safe to call repeatedly from the audio-thread tap.
  ///
  /// This is a streaming, per-buffer helper: `AVAudioConverter` may keep a small
  /// amount of resampler delay internally between calls. Call `drain()` once no
  /// more source buffers will arrive to flush those residual frames before
  /// closing downstream streams.
  public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let capacity = AVAudioFrameCount(
      ceil(Double(input.frameLength) * destinationFormat.sampleRate / sourceFormat.sampleRate)
    ) + Self.resamplerTailHeadroomFrames
    guard capacity > 0,
          let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: capacity)
    else { return nil }

    var didProvideInput = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      if didProvideInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return input
    }
    guard error == nil, output.frameLength > 0 else { return nil }
    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      return output
    case .error:
      return nil
    @unknown default:
      return nil
    }
  }

  /// Signal end-of-stream to the underlying converter and return any residual
  /// output buffers it still holds (typically resampler delay). Call after the
  /// audio engine/tap has stopped producing input and before finishing streams.
  /// After `drain()` the converter must not be reused for `convert(_:)`; discard
  /// this wrapper and build a fresh converter for later input.
  public func drain() -> [AVAudioPCMBuffer] {
    var drained: [AVAudioPCMBuffer] = []

    for iteration in 0..<Self.maxDrainIterations {
      guard let output = AVAudioPCMBuffer(
        pcmFormat: destinationFormat,
        frameCapacity: Self.drainOutputCapacity
      ) else { break }

      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, outStatus in
        outStatus.pointee = .endOfStream
        return nil
      }

      guard error == nil else { break }
      if output.frameLength > 0 {
        drained.append(output)
      }

      switch status {
      case .haveData:
        if iteration == Self.maxDrainIterations - 1 {
          FileHandle.standardError.write(Data(
            "[BufferConverter] drain hit iteration cap; tail truncated\n".utf8
          ))
        }
        continue
      case .inputRanDry, .endOfStream:
        return drained
      case .error:
        return drained
      @unknown default:
        return drained
      }
    }

    return drained
  }
}
