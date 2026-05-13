import AVFoundation
import Foundation
import Speech

/// Source of audio buffers that the live transcription pipeline can consume.
///
/// Conforming sources:
/// - Configure their underlying capture mechanism (`AVAudioEngine`, `SCStream`,
///   `AVAudioFile`, network, etc.) and resolve a *capture* format.
/// - Resolve an *analyzer* format compatible with the supplied transcribers
///   (almost always 16 kHz Int16 mono per `SpeechAnalyzer.bestAvailableAudioFormat`).
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
  /// returned at construction time. Almost always 16 kHz Int16 mono.
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

  /// Begin capture. Idempotent: calling twice is a no-op.
  func start() throws

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
