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

  /// Hard timeout for the AVAudioEngine `start()` call. Engine start has
  /// been observed to stall on misconfigured systems; we refuse to wait
  /// longer than this and surface a clean error.
  public static let startTimeoutSeconds: Double = 10.0

  public func start() async throws {
    guard !started else { return }

    // Preflight TCC. Fails fast with an actionable error instead of
    // letting AVAudioEngine.start() stall on a denied / undetermined
    // microphone grant.
    switch TCCPreflight.microphone() {
    case .granted:
      break
    case .denied, .undetermined:
      throw MicAudioSourceError.microphoneTCCDenied
    }

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
    // AVAudioEngine.start() is synchronous; wrap so a future stall
    // surfaces as a TimeoutError instead of a stuck process. AVAudioEngine
    // is not Sendable so we hop into a detached, audio-engine-bound box.
    let engineRef = MicEngineRef(engine: engine)
    do {
      try await withTimeout(
        seconds: Self.startTimeoutSeconds,
        label: "AVAudioEngine.start"
      ) {
        try engineRef.engine.start()
      }
    } catch is TimeoutError {
      throw MicAudioSourceError.startTimedOut(seconds: Self.startTimeoutSeconds)
    }
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
  /// TCC preflight reported Microphone is denied / undetermined.
  case microphoneTCCDenied
  /// `AVAudioEngine.start()` did not return within the bounded timeout.
  case startTimedOut(seconds: Double)
  case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)

  public var description: String {
    switch self {
    case .microphoneTCCDenied:
      return TCCPreflight.microphoneRemediation
    case .startTimedOut(let s):
      return "AVAudioEngine.start did not complete within \(s)s. \(TCCPreflight.microphoneRemediation)"
    case let .converterUnavailable(from, to):
      return "Could not build AVAudioConverter from \(from) to \(to)"
    }
  }
}

/// Sendable wrapper so the timeout closure can capture an AVAudioEngine
/// reference without a strict-concurrency warning.
private final class MicEngineRef: @unchecked Sendable {
  let engine: AVAudioEngine
  init(engine: AVAudioEngine) { self.engine = engine }
}
