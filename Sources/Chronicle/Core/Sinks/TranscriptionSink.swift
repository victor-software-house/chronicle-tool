import Foundation

/// Consumer of `SpeechTranscriber` result events.
///
/// One pipeline composes many sinks: `LiveFileSink` rewrites a live snapshot,
/// `FinalsAppendSink` appends timestamped finals, `JSONLTraceSink` (FR-2)
/// emits a structured trace, `TagsJSONLSink` (FR-5) tags every N finals.
///
/// Implementations must be safe to call from a single consumer task. They
/// generally `actor`-isolate their internal state and return promptly so
/// downstream sinks are not blocked.
public protocol TranscriptionSink: Sendable {
  /// A new volatile (provisional) hypothesis was emitted. Volatile text may
  /// be revised before the corresponding final arrives.
  func didReceiveVolatile(_ text: String, wallclockOffsetMs: Double) async

  /// A finalised segment was emitted. Finals are immutable.
  func didReceiveFinal(_ text: String, wallclockOffsetMs: Double, wallclock: Date) async

  /// A transcription result with optional audio timing metadata was emitted.
  /// Sinks that do not care about timing route through the volatile/final hooks.
  ///
  /// `speakerId`, when present, is the live diarizer's best guess for the
  /// midpoint of `audioRange`. Sinks that do not care about speakers can
  /// ignore it.
  func didReceiveResult(
    _ text: String,
    isFinal: Bool,
    wallclockOffsetMs: Double,
    wallclock: Date,
    audioRange: TraceAudioRange?,
    speakerId: String?
  ) async

  /// Pipeline is shutting down. Flush + close.
  func finish() async
}

/// Default no-op implementations so each sink only overrides what it cares
/// about.
extension TranscriptionSink {
  public func didReceiveVolatile(_ text: String, wallclockOffsetMs: Double) async {}
  public func didReceiveFinal(_ text: String, wallclockOffsetMs: Double, wallclock: Date) async {}
  public func didReceiveResult(
    _ text: String,
    isFinal: Bool,
    wallclockOffsetMs: Double,
    wallclock: Date,
    audioRange: TraceAudioRange?,
    speakerId: String?
  ) async {
    if isFinal {
      await didReceiveFinal(text, wallclockOffsetMs: wallclockOffsetMs, wallclock: wallclock)
    } else {
      await didReceiveVolatile(text, wallclockOffsetMs: wallclockOffsetMs)
    }
  }
  public func finish() async {}
}
