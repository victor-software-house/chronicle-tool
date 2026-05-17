import AVFoundation
import Foundation
import Speech

/// Source of audio buffers that the live transcription pipeline can consume.
///
/// Conforming sources:
/// - Configure their underlying capture mechanism (`AVAudioEngine`, CoreAudio
///   process tap, `AVAudioFile`, network, etc.) and resolve a *capture* format.
/// - Resolve an *analyzer* format compatible with the supplied transcribers via
///   `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`.
/// - Yield converted `AnalyzerInput` values on `analyzerInputs` for the
///   `SpeechAnalyzer` to consume.
/// - Yield the same audio (in the *analyzer* format) on `pcmBuffers` so that
///   sidecar sinks — WAV writer, Opus encoder, diarizer, live tagger — can
///   share a single zero-copy stream.
///
/// Implementations are responsible for `start()` and `stop()` semantics; they
/// own the capture lifecycle. The pipeline drains `analyzerInputs` until the
/// stream finishes.
public protocol AudioSource: AnyObject, Sendable {
  /// Format of the buffers yielded by `pcmBuffers` and wrapped inside
  /// `analyzerInputs`. Matches what `SpeechAnalyzer.bestAvailableAudioFormat`
  /// returned at construction time. The observed Chronicle live path is often
  /// 16 kHz mono Int16, but callers must not hard-code that shape.
  var analyzerFormat: AVAudioFormat { get }

  /// Async stream of `AnalyzerInput` values to feed into
  /// `SpeechAnalyzer.start(inputSequence:)`.
  var analyzerInputs: AsyncStream<AnalyzerInput> { get }

  /// Async stream of raw `AVAudioPCMBuffer` values (in `analyzerFormat`) for
  /// audio sidecar sinks. Same buffers as `analyzerInputs` (shared reference),
  /// no copy. Multiple consumers should fan-out via `BufferMulticast` when
  /// FR-4 lands; for now a single consumer is supported per source.
  ///
  /// Wrapped in `PCMBufferRef` so the reference-typed `AVAudioPCMBuffer` can
  /// cross `AsyncStream` boundaries under Swift 6 strict concurrency.
  /// Consumers must treat the underlying buffer as read-only; concurrent
  /// reads are safe, concurrent writes are not.
  var pcmBuffers: AsyncStream<PCMBufferRef> { get }

  /// Begin capture. Idempotent: calling twice is a no-op. `async` so
  /// sources that wrap async-throwing system APIs can conform; sync sources
  /// (`AVAudioEngine.start`) simply don't await.
  func start() async throws

  /// End capture. Idempotent. Closes the underlying streams so async
  /// consumers terminate.
  func stop()
}

/// Sendable wrapper around `AVAudioPCMBuffer` so it can travel through
/// `AsyncStream` boundaries. The underlying buffer is a reference type and
/// safe for concurrent *read* access; consumers must not mutate it.
public final class PCMBufferRef: @unchecked Sendable {
  public let buffer: AVAudioPCMBuffer
  public init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Shared analyzer + PCM stream fan-out for live `AudioSource` implementations.
///
/// Sources yield each converted buffer once here; the helper wraps it for
/// SpeechAnalyzer and the sidecar stream in one place. This keeps stop/drain
/// ordering consistent across audio sources.
///
/// Source identity is intentionally outside `AnalyzerInput`: current `mic` and
/// `sysaudio` commands run one source per transcriber. A future multi-source
/// daemon must preserve source labels before merging streams; feeding mic and
/// system buffers into one raw `AnalyzerInput` sequence would lose source
/// awareness at the SpeechAnalyzer boundary.
final class AudioSourceOutputStreams: @unchecked Sendable {
  let analyzerInputs: AsyncStream<AnalyzerInput>
  let pcmBuffers: AsyncStream<PCMBufferRef>

  private let analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation
  private let pcmContinuation: AsyncStream<PCMBufferRef>.Continuation

  init() {
    var analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation!
    // Unbounded: live audio callbacks cannot backpressure; consumers must drain promptly.
    self.analyzerInputs = AsyncStream(bufferingPolicy: .unbounded) { analyzerContinuation = $0 }
    self.analyzerContinuation = analyzerContinuation

    var pcmContinuation: AsyncStream<PCMBufferRef>.Continuation!
    self.pcmBuffers = AsyncStream(bufferingPolicy: .unbounded) { pcmContinuation = $0 }
    self.pcmContinuation = pcmContinuation
  }

  func yield(_ buffer: AVAudioPCMBuffer) {
    analyzerContinuation.yield(AnalyzerInput(buffer: buffer))
    pcmContinuation.yield(PCMBufferRef(buffer))
  }

  func yieldAll(_ buffers: some Sequence<AVAudioPCMBuffer>) {
    for buffer in buffers {
      yield(buffer)
    }
  }

  func finish() {
    analyzerContinuation.finish()
    pcmContinuation.finish()
  }
}
