import Foundation
import AVFoundation
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
    // Sort + merge consecutive same-speaker segments would be nice; for now
    // we just sort by start time so binary-search lookups remain easy.
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
    // Linear scan is fine for typical timelines (≤ thousands of segments).
    // If this becomes hot, replace with binary search on sorted starts.
    for segment in segments {
      if time >= segment.startSeconds, time < segment.endSeconds {
        return segment.speakerId
      }
    }
    return nil
  }
}

// MARK: - Sortformer-backed streaming diarizer

/// Production streaming diarizer backed by FluidAudio's `SortformerDiarizer`.
///
/// Lifecycle:
///
/// * Lazily downloads or loads Sortformer CoreML models on the first ingest.
/// * Converts each PCM buffer to 16 kHz mono `Float`, feeds it into the
///   model, and triggers `process()` every `processEverySamples` to keep
///   incremental cost bounded.
/// * After each `process()`/`finalizeSession()` it rebuilds an internal
///   `DiarizationTimelineLookup` snapshot so subsequent
///   `speakerId(forRange:)` calls are lock-free reads.
///
/// Speaker ID stability across the streaming session is provided by
/// Sortformer's own state updater (best-effort, not guaranteed identical
/// across separate runs).
public actor SortformerStreamingDiarizer: StreamingDiarizing {
  /// Target sample rate the diarizer model expects.
  public static let targetSampleRate: Double = 16_000.0

  /// Run `process()` after roughly this many samples are buffered to keep
  /// per-call cost bounded. 16 000 samples = 1 s @ 16 kHz mono.
  public static let defaultProcessEverySamples: Int = 16_000

  private let logTag: String
  private let processEverySamples: Int

  private var diarizer: SortformerDiarizer?
  private var pendingSamples: Int = 0
  private var lookup: DiarizationTimelineLookup = DiarizationTimelineLookup(segments: [])
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var converterOutputFormat: AVAudioFormat?
  private var initFailureLogged: Bool = false

  public init(
    logTag: String = "diarize",
    processEverySamples: Int = SortformerStreamingDiarizer.defaultProcessEverySamples
  ) {
    self.logTag = logTag
    self.processEverySamples = processEverySamples
  }

  public func ingest(_ bufferRef: PCMBufferRef) async throws {
    let diarizer = try await ensureLoaded()
    guard let floats = convertToTargetFloat(bufferRef.buffer) else { return }
    try diarizer.addAudio(floats, sourceSampleRate: nil)
    pendingSamples += floats.count
    if pendingSamples >= processEverySamples {
      pendingSamples = 0
      if let update = try diarizer.process() {
        absorb(timelineUpdate: update)
      }
    }
  }

  public func speakerId(forRange range: TraceAudioRange) -> String? {
    lookup.speakerId(forRange: range)
  }

  public func finish() async {
    guard let diarizer else { return }
    do {
      if let update = try diarizer.finalizeSession() {
        absorb(timelineUpdate: update)
      }
    } catch {
      FileHandle.standardError.write(Data(
        "[\(logTag)] finalize failed: \(error)\n".utf8
      ))
    }
  }

  public var currentLookup: DiarizationTimelineLookup { lookup }

  // MARK: - Internals

  private func ensureLoaded() async throws -> SortformerDiarizer {
    if let diarizer { return diarizer }
    FileHandle.standardError.write(Data(
      "[\(logTag)] downloading or loading Sortformer streaming models...\n".utf8
    ))
    let config = SortformerConfig.default
    let models = try await SortformerModels.loadFromHuggingFace(config: config)
    let mgr = SortformerDiarizer(config: config)
    mgr.initialize(models: models)
    self.diarizer = mgr
    FileHandle.standardError.write(Data("[\(logTag)] streaming models ready\n".utf8))
    return mgr
  }

  private func absorb(timelineUpdate update: DiarizerTimelineUpdate) {
    var segments: [DiarizationSegment] = []
    // Take finalized + tentative; tentative gives us coverage for the
    // most recent ~1 s window so live finals can be labelled immediately.
    let frameSegments = update.finalizedSegments + update.tentativeSegments
    for s in frameSegments {
      segments.append(
        DiarizationSegment(
          speakerId: "S\(s.speakerIndex)",
          startSeconds: Double(s.startTime),
          endSeconds: Double(s.endTime)
        )
      )
    }
    // Merge with previous lookup so older finalized segments survive.
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
    // Keep all previous segments that end strictly before the earliest
    // newer segment starts; replace the overlapping tail with the new view.
    guard let firstNewStart = newer.map(\.startSeconds).min() else {
      return previous
    }
    let kept = previous.filter { $0.endSeconds <= firstNewStart }
    return kept + newer
  }

  private func convertToTargetFloat(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    let inputFormat = buffer.format
    if inputFormat.sampleRate == Self.targetSampleRate,
       inputFormat.commonFormat == .pcmFormatFloat32,
       inputFormat.channelCount == 1,
       let ptr = buffer.floatChannelData?.pointee {
      let count = Int(buffer.frameLength)
      let bp = UnsafeBufferPointer(start: ptr, count: count)
      return Array(bp)
    }

    let outFormat: AVAudioFormat
    if let cached = converterOutputFormat, let _ = converter,
       inputFormat == converterInputFormat {
      outFormat = cached
    } else {
      guard let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.targetSampleRate,
        channels: 1,
        interleaved: false
      ) else {
        if !initFailureLogged {
          FileHandle.standardError.write(Data(
            "[\(logTag)] could not build target 16 kHz mono float format\n".utf8
          ))
          initFailureLogged = true
        }
        return nil
      }
      guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
        if !initFailureLogged {
          FileHandle.standardError.write(Data(
            "[\(logTag)] could not build AVAudioConverter \(inputFormat) -> \(target)\n".utf8
          ))
          initFailureLogged = true
        }
        return nil
      }
      self.converter = conv
      self.converterInputFormat = inputFormat
      self.converterOutputFormat = target
      outFormat = target
    }

    // Worst-case output frame count: roundUp(inFrames * outRate / inRate).
    let inputFrames = Double(buffer.frameLength)
    let ratio = outFormat.sampleRate / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 32
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
      FileHandle.standardError.write(Data(
        "[\(logTag)] convert failed: \(error?.localizedDescription ?? "unknown")\n".utf8
      ))
      return nil
    }
    let outCount = Int(outBuffer.frameLength)
    guard outCount > 0, let outPtr = outBuffer.floatChannelData?.pointee else {
      return nil
    }
    return Array(UnsafeBufferPointer(start: outPtr, count: outCount))
  }
}
