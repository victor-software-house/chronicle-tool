import AVFoundation
import Foundation
@preconcurrency import FluidAudio

/// Live-stream diarization protocol. The offline counterpart is
/// `OfflineDiarizing`; the streaming variant ingests `AVAudioPCMBuffer`s as
/// they arrive from an `AudioSource` and exposes a `speakerId(forRange:)`
/// lookup for transcription sinks to attach speakers to live finals.
///
/// Contract:
///
/// * `ingest(_:)` is non-blocking from the source callback's perspective; the
///   implementation should off-load model inference to its own task and not
///   block the caller.
/// * `speakerId(forRange:)` returns the best-known speaker label for the
///   midpoint of `range` based on the most-recent timeline. `nil` means
///   "unknown yet" (no segment overlaps the range or the timeline has not
///   produced finalized output yet).
/// * `finish()` drains residual audio, finalises the session, and updates
///   the timeline one last time.
public protocol StreamingDiarizing: Sendable {
  /// Feed one audio buffer into the diarizer. Implementation owns sample
  /// conversion to whatever the model expects (typically 16 kHz mono float).
  /// `PCMBufferRef` is the `Sendable` wrapper used by the live audio sources.
  func ingest(_ bufferRef: PCMBufferRef) async throws

  /// Query the current timeline for the speaker active at the midpoint of
  /// `range`. Returns a stable label such as `"S0"`, `"S1"`.
  func speakerId(forRange range: TraceAudioRange) async -> String?

  /// Drain remaining audio and finalise the streaming session.
  func finish() async
}

// MARK: - Timeline lookup helper

/// In-process snapshot of `[DiarizationSegment]` that answers
/// `speakerId(forRange:)` queries by checking the midpoint of the requested
/// range. Pure value type so it can be unit-tested without loading any
/// CoreML model; concrete `StreamingDiarizing` implementations rebuild a
/// new snapshot after each model update.
public struct DiarizationTimelineLookup: Sendable {
  public let segments: [DiarizationSegment]

  public init(segments: [DiarizationSegment]) {
    self.segments = segments.sorted { lhs, rhs in
      if lhs.startSeconds == rhs.startSeconds {
        return lhs.endSeconds < rhs.endSeconds
      }
      return lhs.startSeconds < rhs.startSeconds
    }
  }

  /// Return the speaker label whose `[startSeconds, endSeconds]` interval
  /// contains the midpoint of `range`. Inclusive of `startSeconds`,
  /// exclusive of `endSeconds`. Returns `nil` when no segment covers the
  /// midpoint.
  public func speakerId(forRange range: TraceAudioRange) -> String? {
    let midpoint = (range.startSeconds + range.endSeconds) / 2.0
    return speakerId(at: midpoint)
  }

  public func speakerId(at time: Double) -> String? {
    for segment in segments {
      if time >= segment.startSeconds, time < segment.endSeconds {
        return segment.speakerId
      }
    }
    return nil
  }
}

// MARK: - Backend abstraction

/// Plain timeline update emitted by a streaming-diarizer backend. Decouples
/// our streaming wrapper from FluidAudio types so tests can stub the
/// backend without depending on CoreML.
public struct StreamingDiarizerUpdate: Sendable, Equatable {
  public let finalizedSegments: [DiarizationSegment]
  public let tentativeSegments: [DiarizationSegment]

  public init(
    finalizedSegments: [DiarizationSegment] = [],
    tentativeSegments: [DiarizationSegment] = []
  ) {
    self.finalizedSegments = finalizedSegments
    self.tentativeSegments = tentativeSegments
  }
}

/// Streaming-diarizer model backend. Production: wraps FluidAudio's
/// `SortformerDiarizer`. Tests: stub that records calls.
public protocol StreamingDiarizerBackend: AnyObject, Sendable {
  /// Lazily download / load the underlying model. May be expensive; only
  /// called from the actor's ingest path.
  func load() async throws

  /// Feed one chunk of 16 kHz mono float samples into the model.
  func addAudio(_ samples: [Float]) throws

  /// Run the model. Returns `nil` if no new prediction is available yet.
  func process() throws -> StreamingDiarizerUpdate?

  /// Finalise the session and return any residual prediction.
  func finalize() throws -> StreamingDiarizerUpdate?
}

/// Production backend wrapping FluidAudio's `SortformerDiarizer`.
final class SortformerBackend: StreamingDiarizerBackend, @unchecked Sendable {
  private var diarizer: SortformerDiarizer?
  private let logTag: String

  init(logTag: String) {
    self.logTag = logTag
  }

  func load() async throws {
    if diarizer != nil { return }
    FileHandle.standardError.write(Data(
      "[\(logTag)] downloading or loading Sortformer streaming models...\n".utf8
    ))
    let config = SortformerConfig.default
    let models = try await SortformerModels.loadFromHuggingFace(config: config)
    let mgr = SortformerDiarizer(config: config)
    mgr.initialize(models: models)
    self.diarizer = mgr
    FileHandle.standardError.write(Data("[\(logTag)] streaming models ready\n".utf8))
  }

  func addAudio(_ samples: [Float]) throws {
    guard let diarizer else { throw StreamingDiarizerError.notLoaded }
    try diarizer.addAudio(samples, sourceSampleRate: nil)
  }

  func process() throws -> StreamingDiarizerUpdate? {
    guard let diarizer else { throw StreamingDiarizerError.notLoaded }
    return try diarizer.process().map(Self.toUpdate(_:))
  }

  func finalize() throws -> StreamingDiarizerUpdate? {
    guard let diarizer else { return nil }
    return try diarizer.finalizeSession().map(Self.toUpdate(_:))
  }

  private static func toUpdate(_ tl: DiarizerTimelineUpdate) -> StreamingDiarizerUpdate {
    StreamingDiarizerUpdate(
      finalizedSegments: tl.finalizedSegments.map(Self.toSegment(_:)),
      tentativeSegments: tl.tentativeSegments.map(Self.toSegment(_:))
    )
  }

  private static func toSegment(_ s: DiarizerSegment) -> DiarizationSegment {
    DiarizationSegment(
      speakerId: "S\(s.speakerIndex)",
      startSeconds: Double(s.startTime),
      endSeconds: Double(s.endTime)
    )
  }
}

public enum StreamingDiarizerError: Error, CustomStringConvertible {
  case notLoaded
  public var description: String {
    switch self {
    case .notLoaded: return "Streaming diarizer backend has not been loaded yet."
    }
  }
}

// MARK: - Streaming diarizer

/// Production streaming diarizer. Composes a `PCMFloatConverter` (audio
/// format normalization) with a `StreamingDiarizerBackend` (model). Default
/// production initialiser uses `SortformerBackend`; tests inject a stub.
///
/// Lifecycle:
///
/// * Lazily calls `backend.load()` on the first ingest.
/// * Converts each PCM buffer to 16 kHz mono `Float`, calls `addAudio`, and
///   triggers `process()` every `processEverySamples` to keep incremental
///   cost bounded.
/// * After each `process()` / `finalize()` it rebuilds an internal
///   `DiarizationTimelineLookup` snapshot so subsequent
///   `speakerId(forRange:)` calls are lock-free reads.
public actor SortformerStreamingDiarizer: StreamingDiarizing {
  /// Target sample rate the diarizer model expects.
  public static let targetSampleRate: Double = 16_000.0

  /// Run `process()` after roughly this many samples are buffered to keep
  /// per-call cost bounded. 16 000 samples = 1 s @ 16 kHz mono.
  public static let defaultProcessEverySamples: Int = 16_000

  private let logTag: String
  private let processEverySamples: Int
  private let diagnosticInterval: TimeInterval
  private let backend: StreamingDiarizerBackend
  private let pcmConverter: PCMFloatConverter

  private var loaded: Bool = false
  private var loadTask: Task<Void, Error>?
  private var pendingSamples: Int = 0
  private var totalSamplesIngested: Int = 0
  private var ingestCallCount: Int = 0
  private var processCallCount: Int = 0
  private var processNonNilUpdateCount: Int = 0
  private var totalFinalizedSegments: Int = 0
  private var totalTentativeSegments: Int = 0
  private var lookupQueryCount: Int = 0
  private var lookupHitCount: Int = 0
  private var lastDiagnosticAt: ContinuousClock.Instant?
  private var finalized: Bool = false
  private var lookup: DiarizationTimelineLookup = DiarizationTimelineLookup(segments: [])

  /// Test/Production initialiser. Pass a custom `backend` (and optionally a
  /// custom converter) to stub the model layer.
  public init(
    logTag: String = "diarize",
    processEverySamples: Int = SortformerStreamingDiarizer.defaultProcessEverySamples,
    diagnosticIntervalSeconds: TimeInterval = 5.0,
    backend: StreamingDiarizerBackend? = nil,
    pcmConverter: PCMFloatConverter? = nil
  ) {
    self.logTag = logTag
    self.processEverySamples = processEverySamples
    self.diagnosticInterval = diagnosticIntervalSeconds
    self.backend = backend ?? SortformerBackend(logTag: logTag)
    self.pcmConverter = pcmConverter ?? PCMFloatConverter(targetSampleRate: Self.targetSampleRate)
  }

  public func ingest(_ bufferRef: PCMBufferRef) async throws {
    try await ensureLoaded()
    guard let floats = pcmConverter.convert(bufferRef.buffer) else {
      if let err = pcmConverter.lastErrorDescription {
        FileHandle.standardError.write(Data(
          "[\(logTag)] pcm convert failed: \(err)\n".utf8
        ))
      }
      return
    }
    do {
      try backend.addAudio(floats)
    } catch {
      FileHandle.standardError.write(Data(
        "[\(logTag)] addAudio failed: \(error)\n".utf8
      ))
      return
    }
    ingestCallCount += 1
    pendingSamples += floats.count
    totalSamplesIngested += floats.count
    if pendingSamples >= processEverySamples {
      pendingSamples = 0
      processCallCount += 1
      do {
        if let update = try backend.process() {
          processNonNilUpdateCount += 1
          absorb(update)
        }
      } catch {
        FileHandle.standardError.write(Data(
          "[\(logTag)] process() threw: \(error)\n".utf8
        ))
      }
    }
    maybeEmitDiagnostic()
  }

  public func prepare() async throws {
    try await ensureLoaded()
  }

  public func speakerId(forRange range: TraceAudioRange) -> String? {
    lookupQueryCount += 1
    let result = lookup.speakerId(forRange: range)
    if result != nil { lookupHitCount += 1 }
    return result
  }

  public func finish() async {
    guard !finalized else { return }
    finalized = true
    guard loaded, totalSamplesIngested > 0 else {
      FileHandle.standardError.write(Data(
        "[\(logTag)] skipping finalize: loaded=\(loaded) samples=\(totalSamplesIngested)\n".utf8
      ))
      emitFinalDiagnostic()
      return
    }
    do {
      if let update = try backend.finalize() {
        processNonNilUpdateCount += 1
        absorb(update)
      }
    } catch {
      FileHandle.standardError.write(Data(
        "[\(logTag)] finalize failed: \(error)\n".utf8
      ))
    }
    emitFinalDiagnostic()
  }

  // MARK: - Test accessors

  public var currentLookup: DiarizationTimelineLookup { lookup }
  public var debugIngestCallCount: Int { ingestCallCount }
  public var debugProcessCallCount: Int { processCallCount }
  public var debugTotalSamplesIngested: Int { totalSamplesIngested }
  public var debugLookupQueryCount: Int { lookupQueryCount }
  public var debugLookupHitCount: Int { lookupHitCount }

  // MARK: - Internals

  private func ensureLoaded() async throws {
    if loaded { return }
    if let loadTask {
      try await loadTask.value
      loaded = true
      self.loadTask = nil
      return
    }

    let task = Task { try await backend.load() }
    loadTask = task
    do {
      try await task.value
      loaded = true
      loadTask = nil
    } catch {
      loadTask = nil
      throw error
    }
  }

  private func absorb(_ update: StreamingDiarizerUpdate) {
    totalFinalizedSegments += update.finalizedSegments.count
    totalTentativeSegments += update.tentativeSegments.count
    let segments = update.finalizedSegments + update.tentativeSegments
    let combined = mergeSegmentsKeepingNewer(
      previous: lookup.segments,
      newer: segments
    )
    lookup = DiarizationTimelineLookup(segments: combined)
  }

  private func mergeSegmentsKeepingNewer(
    previous: [DiarizationSegment],
    newer: [DiarizationSegment]
  ) -> [DiarizationSegment] {
    guard !newer.isEmpty else { return previous }
    guard let firstNewStart = newer.map(\.startSeconds).min() else {
      return previous
    }
    let kept = previous.filter { $0.endSeconds <= firstNewStart }
    return kept + newer
  }

  private func maybeEmitDiagnostic() {
    let now = ContinuousClock.now
    guard let last = lastDiagnosticAt else {
      lastDiagnosticAt = now
      return
    }
    let elapsed = now - last
    if elapsed >= .seconds(diagnosticInterval) {
      lastDiagnosticAt = now
      emitDiagnostic(label: "tick")
    }
  }

  private func emitFinalDiagnostic() {
    emitDiagnostic(label: "final")
  }

  private func emitDiagnostic(label: String) {
    let segCount = lookup.segments.count
    let speakers = Set(lookup.segments.map(\.speakerId)).count
    let audioSec = Double(totalSamplesIngested) / Self.targetSampleRate
    let line = "[\(logTag).diag \(label)] ingest=\(ingestCallCount) audio=\(String(format: "%.1f", audioSec))s process=\(processCallCount) updates=\(processNonNilUpdateCount) segments=\(segCount) speakers=\(speakers) finalized=\(totalFinalizedSegments) tentative=\(totalTentativeSegments) lookups=\(lookupQueryCount) hits=\(lookupHitCount)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}
