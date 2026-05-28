import Foundation

public final class LiveResultClock: @unchecked Sendable {
  private let lock = NSLock()
  private var start: ContinuousClock.Instant?

  public init() {}

  public func markStarted(_ instant: ContinuousClock.Instant = ContinuousClock.now) {
    lock.withLock {
      start = instant
    }
  }

  public func millisecondsSinceStart(_ now: ContinuousClock.Instant = ContinuousClock.now) -> Double {
    let baseline = lock.withLock { start }
    guard let baseline else { return 0.0 }
    return MonotonicClock.milliseconds(since: baseline, now: now)
  }
}

/// Lightweight live latency tracker for SpeechAnalyzer result events.
///
/// `wallclockOffsetMs` is the monotonic offset at result receipt. `audioRange`
/// is the SpeechAnalyzer audio range covered by the result. The actionable
/// latency metric is receipt minus audio end: how long after the spoken audio
/// ended did Chronicle observe the transcript update?
public struct TranscriptionLatencySample: Equatable, Sendable {
  public let latencyMs: Double
  public let audioEndSeconds: Double
  public let receiptOffsetMs: Double
  public let isFinal: Bool
  public let speakerKnown: Bool

  public init(
    latencyMs: Double,
    audioEndSeconds: Double,
    receiptOffsetMs: Double,
    isFinal: Bool,
    speakerKnown: Bool
  ) {
    self.latencyMs = latencyMs
    self.audioEndSeconds = audioEndSeconds
    self.receiptOffsetMs = receiptOffsetMs
    self.isFinal = isFinal
    self.speakerKnown = speakerKnown
  }
}

public struct TranscriptionLatencySnapshot: Equatable, Sendable {
  public let label: String
  public let latestMs: Double
  public let averageMs: Double
  public let p95Ms: Double
  public let maxMs: Double
  public let sampleCount: Int
  public let finalCount: Int
  public let speakerKnownCount: Int
  public let speakerUnknownCount: Int

  public var lineSuffix: String {
    "latest=\(Self.ms(latestMs)) avg=\(Self.ms(averageMs)) p95=\(Self.ms(p95Ms)) max=\(Self.ms(maxMs)) samples=\(sampleCount) finals=\(finalCount) speakerKnown=\(speakerKnownCount) speakerUnknown=\(speakerUnknownCount)"
  }

  private static func ms(_ value: Double) -> String {
    "\(Int(value.rounded()))ms"
  }
}

/// In-memory rolling stats. Deliberately not an actor: live subcommands call
/// it from their single result-consumer task.
public struct TranscriptionLatencyMonitor: Sendable {
  private let logTag: String
  private let diagnosticIntervalMs: Double
  private let warnLatencyMs: Double
  private let maxSamples: Int

  private var samples: [TranscriptionLatencySample] = []
  private var lastDiagnosticOffsetMs: Double?
  private var finalCount: Int = 0
  private var speakerKnownCount: Int = 0
  private var speakerUnknownCount: Int = 0

  public init(
    logTag: String,
    diagnosticIntervalSeconds: Double = 5.0,
    warnLatencyMs: Double = 1_500.0,
    maxSamples: Int = 512
  ) {
    self.logTag = logTag
    self.diagnosticIntervalMs = diagnosticIntervalSeconds * 1_000.0
    self.warnLatencyMs = warnLatencyMs
    self.maxSamples = max(16, maxSamples)
  }

  public mutating func record(
    isFinal: Bool,
    wallclockOffsetMs: Double,
    audioRange: TraceAudioRange?,
    speakerId: String?
  ) -> TranscriptionLatencySnapshot? {
    guard let sample = makeSample(
      isFinal: isFinal,
      wallclockOffsetMs: wallclockOffsetMs,
      audioRange: audioRange,
      speakerId: speakerId
    ) else { return nil }

    samples.append(sample)
    if samples.count > maxSamples {
      samples.removeFirst(samples.count - maxSamples)
    }
    if isFinal { finalCount += 1 }
    if sample.speakerKnown {
      speakerKnownCount += 1
    } else {
      speakerUnknownCount += 1
    }

    let dueForTick: Bool
    if let lastDiagnosticOffsetMs {
      dueForTick = wallclockOffsetMs - lastDiagnosticOffsetMs >= diagnosticIntervalMs
    } else {
      dueForTick = true
    }
    let shouldWarn = sample.latencyMs >= warnLatencyMs
    let shouldEmitWarn = shouldWarn && dueForTick
    guard isFinal || dueForTick else { return nil }

    lastDiagnosticOffsetMs = wallclockOffsetMs
    return snapshot(label: shouldEmitWarn ? "warn" : (isFinal ? "final" : "tick"), latestMs: sample.latencyMs)
  }

  public func finalSnapshot() -> TranscriptionLatencySnapshot? {
    guard let latest = samples.last else { return nil }
    return snapshot(label: "summary", latestMs: latest.latencyMs)
  }

  public static func transcriptionLatencyMs(
    wallclockOffsetMs: Double,
    audioRange: TraceAudioRange?
  ) -> Double? {
    guard let audioRange else { return nil }
    let endOffsetMs = audioRange.endSeconds * 1_000.0
    guard wallclockOffsetMs.isFinite, endOffsetMs.isFinite else { return nil }
    return wallclockOffsetMs - endOffsetMs
  }

  public static func emit(logTag: String, snapshot: TranscriptionLatencySnapshot) {
    FileHandle.standardError.write(Data(
      "[\(logTag).latency \(snapshot.label)] \(snapshot.lineSuffix)\n".utf8
    ))
  }

  private func makeSample(
    isFinal: Bool,
    wallclockOffsetMs: Double,
    audioRange: TraceAudioRange?,
    speakerId: String?
  ) -> TranscriptionLatencySample? {
    guard let latencyMs = Self.transcriptionLatencyMs(
      wallclockOffsetMs: wallclockOffsetMs,
      audioRange: audioRange
    ), let audioRange else { return nil }
    return TranscriptionLatencySample(
      latencyMs: latencyMs,
      audioEndSeconds: audioRange.endSeconds,
      receiptOffsetMs: wallclockOffsetMs,
      isFinal: isFinal,
      speakerKnown: speakerId != nil
    )
  }

  private func snapshot(label: String, latestMs: Double) -> TranscriptionLatencySnapshot {
    let values = samples.map(\.latencyMs).sorted()
    let average = values.reduce(0.0, +) / Double(values.count)
    let p95Index = min(values.count - 1, Int((Double(values.count - 1) * 0.95).rounded(.up)))
    return TranscriptionLatencySnapshot(
      label: label,
      latestMs: latestMs,
      averageMs: average,
      p95Ms: values[p95Index],
      maxMs: values.last ?? latestMs,
      sampleCount: samples.count,
      finalCount: finalCount,
      speakerKnownCount: speakerKnownCount,
      speakerUnknownCount: speakerUnknownCount
    )
  }
}
