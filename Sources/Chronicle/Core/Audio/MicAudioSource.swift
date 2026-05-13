import AVFoundation
import Foundation
import Speech

/// `AudioSource` backed by `AVAudioEngine` with an `installTap` on the input
/// node. Owns the engine + converter lifecycle.
///
/// Construction order:
/// 1. Caller resolves the desired `analyzerFormat` via
///    `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`.
/// 2. `MicAudioSource(analyzerFormat:)` builds the engine, reads the mic's
///    native format, builds a `BufferConverter`, and prepares the async
///    streams.
/// 3. Caller calls `start()` to install the tap and start the engine.
/// 4. Caller drains `analyzerInputs` (and optionally `pcmBuffers`).
/// 5. Caller calls `stop()` to remove the tap, stop the engine, and finish
///    the streams.
public final class MicAudioSource: AudioSource, @unchecked Sendable {
  public let analyzerFormat: AVAudioFormat
  public let micFormat: AVAudioFormat
  public let analyzerInputs: AsyncStream<AnalyzerInput>
  public let pcmBuffers: AsyncStream<PCMBufferRef>

  private let engine: AVAudioEngine
  private let inputNode: AVAudioInputNode
  private let converter: BufferConverter
  private let analyzerBuilder: AsyncStream<AnalyzerInput>.Continuation
  private let pcmBuilder: AsyncStream<PCMBufferRef>.Continuation
  private var started = false
  private var stopped = false

  public init(analyzerFormat: AVAudioFormat) throws {
    self.engine = AVAudioEngine()
    self.inputNode = engine.inputNode
    self.micFormat = inputNode.outputFormat(forBus: 0)
    self.analyzerFormat = analyzerFormat
    guard let converter = BufferConverter(from: micFormat, to: analyzerFormat) else {
      throw MicAudioSourceError.converterUnavailable(from: micFormat, to: analyzerFormat)
    }
    self.converter = converter

    var aBuilder: AsyncStream<AnalyzerInput>.Continuation!
    self.analyzerInputs = AsyncStream { aBuilder = $0 }
    self.analyzerBuilder = aBuilder

    var pBuilder: AsyncStream<PCMBufferRef>.Continuation!
    self.pcmBuffers = AsyncStream { pBuilder = $0 }
    self.pcmBuilder = pBuilder
  }

  public func start() throws {
    guard !started else { return }
    started = true

    let micFormat = self.micFormat
    let converter = self.converter
    let analyzerBuilder = self.analyzerBuilder
    let pcmBuilder = self.pcmBuilder

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
      guard let converted = converter.convert(buffer) else { return }
      analyzerBuilder.yield(AnalyzerInput(buffer: converted))
      pcmBuilder.yield(PCMBufferRef(converted))
    }

    engine.prepare()
    try engine.start()
  }

  public func stop() {
    guard started, !stopped else { return }
    stopped = true
    engine.stop()
    inputNode.removeTap(onBus: 0)
    analyzerBuilder.finish()
    pcmBuilder.finish()
  }
}

public enum MicAudioSourceError: Error, CustomStringConvertible {
  case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)

  public var description: String {
    switch self {
    case let .converterUnavailable(from, to):
      return "Could not build AVAudioConverter from \(from) to \(to)"
    }
  }
}
