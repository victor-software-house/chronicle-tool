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
  private let converter: AVAudioConverter

  public init?(from source: AVAudioFormat, to destination: AVAudioFormat) {
    guard let conv = AVAudioConverter(from: source, to: destination) else { return nil }
    self.sourceFormat = source
    self.destinationFormat = destination
    self.converter = conv
  }

  /// Convert `input` to `destinationFormat`. Returns `nil` on conversion error
  /// or zero-frame output. Safe to call repeatedly from the audio-thread tap.
  public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let capacity = AVAudioFrameCount(
      Double(input.frameLength) * destinationFormat.sampleRate / sourceFormat.sampleRate
    )
    guard capacity > 0,
          let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: capacity)
    else { return nil }

    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      outStatus.pointee = .haveData
      return input
    }
    return status == .haveData ? output : nil
  }
}
