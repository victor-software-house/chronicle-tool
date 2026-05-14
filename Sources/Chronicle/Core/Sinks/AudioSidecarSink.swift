import Foundation
import AVFoundation

/// Sink for the raw-audio sidecar branch of the live pipeline.
///
/// `MicAudioSource` and `SysAudioSource` both produce `AsyncStream<PCMBufferRef>`
/// in the analyzer's input format (typically 16 kHz Float32 mono). A live
/// subcommand attaches at most one `AudioSidecarSink` and drains the stream
/// into it; the same protocol lets us swap the on-disk codec (WAV, Opus-in-CAF,
/// raw PCM scratch) without changing the subcommand.
///
/// Implementations are single-writer: the subcommand drives them from one
/// `Task` consuming the PCM `AsyncStream`. They must not be invoked
/// concurrently from multiple tasks.
///
/// See ADR-0002 for the codec/container decision and PRD-001 FR-1 for the
/// resilience contract.
public protocol AudioSidecarSink: Sendable {
  /// Write one PCM buffer. Format is whatever the underlying `AudioSource`
  /// produces (analyzer format). Implementations are responsible for any
  /// format conversion (e.g. Opus 48 kHz upsample).
  func append(_ buffer: AVAudioPCMBuffer) async

  /// Flush, drain any encoder state, close the underlying file. After
  /// `finish()` the sink must not receive more `append(_:)` calls.
  func finish() async
}
