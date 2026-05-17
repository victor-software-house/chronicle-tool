import Foundation

public enum TraceEventKind: String, Codable, Sendable {
  case volatile
  case final
  case control
  case tag
}

public enum TraceSourceKind: String, Codable, Sendable {
  case microphone
  case systemOutput = "system-output"
  case file
  case unknown
}

public struct TraceAudioRange: Codable, Equatable, Sendable {
  public let startSeconds: Double
  public let endSeconds: Double

  public init(startSeconds: Double, endSeconds: Double) {
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
  }
}

/// Stable source-aware JSONL event used by live transcription, merge,
/// diarization, locale switching, and future export policy.
///
/// Keep this schema additive. Existing field names become downstream contracts
/// after FR-2 lands.
public struct TraceEvent: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let eventId: Int
  public let source: String
  public let sourceKind: TraceSourceKind
  public let streamId: String
  public let wallclock: Date
  public let monotonicOffsetMs: Double
  public let eventKind: TraceEventKind
  public let text: String
  public let isFinal: Bool
  public let locale: String
  public let preset: String
  public let speakerId: String?
  public let audioRange: TraceAudioRange?
  public let audioSegmentPath: String?
  public let channelPolicy: String?
  public let exportPolicy: String?

  public init(
    schemaVersion: Int = 1,
    eventId: Int,
    source: String,
    sourceKind: TraceSourceKind,
    streamId: String,
    wallclock: Date,
    monotonicOffsetMs: Double,
    eventKind: TraceEventKind,
    text: String,
    isFinal: Bool,
    locale: String,
    preset: String,
    speakerId: String? = nil,
    audioRange: TraceAudioRange? = nil,
    audioSegmentPath: String? = nil,
    channelPolicy: String? = nil,
    exportPolicy: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.eventId = eventId
    self.source = source
    self.sourceKind = sourceKind
    self.streamId = streamId
    self.wallclock = wallclock
    self.monotonicOffsetMs = monotonicOffsetMs
    self.eventKind = eventKind
    self.text = text
    self.isFinal = isFinal
    self.locale = locale
    self.preset = preset
    self.speakerId = speakerId
    self.audioRange = audioRange
    self.audioSegmentPath = audioSegmentPath
    self.channelPolicy = channelPolicy
    self.exportPolicy = exportPolicy
  }
}

public struct JSONLTraceReadResult: Sendable {
  public let events: [TraceEvent]
  public let recoveredTrailingLine: Bool

  public init(events: [TraceEvent], recoveredTrailingLine: Bool) {
    self.events = events
    self.recoveredTrailingLine = recoveredTrailingLine
  }
}

public struct JSONLTraceSinkStats: Equatable, Sendable {
  public let writtenEvents: Int
  public let droppedEvents: Int
  public let lastErrorDescription: String?

  public init(writtenEvents: Int, droppedEvents: Int, lastErrorDescription: String?) {
    self.writtenEvents = writtenEvents
    self.droppedEvents = droppedEvents
    self.lastErrorDescription = lastErrorDescription
  }
}

public struct JSONLTraceSinkFailure: Error, CustomStringConvertible, Sendable {
  public let stats: JSONLTraceSinkStats

  public init(stats: JSONLTraceSinkStats) {
    self.stats = stats
  }

  public var description: String {
    if let lastErrorDescription = stats.lastErrorDescription {
      return "JSONL trace sink dropped \(stats.droppedEvents) event(s); lastError=\(lastErrorDescription)"
    }
    return "JSONL trace sink dropped \(stats.droppedEvents) event(s)"
  }
}

public enum JSONLTraceRecoveryError: Error, CustomStringConvertible {
  case malformedLine(url: URL, line: Int, contents: String)

  public var description: String {
    switch self {
    case .malformedLine(let url, let line, let contents):
      "Malformed JSONL trace event at \(url.path):\(line): \(contents)"
    }
  }
}

private enum TraceDateCoding {
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(from string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }

    let wholeSecond = ISO8601DateFormatter()
    wholeSecond.formatOptions = [.withInternetDateTime]
    return wholeSecond.date(from: string)
  }

  static let encodingStrategy = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
    var container = encoder.singleValueContainer()
    try container.encode(string(from: date))
  }

  static let decodingStrategy = JSONDecoder.DateDecodingStrategy.custom { decoder in
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let date = date(from: string) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid ISO8601 wallclock timestamp: \(string)"
      )
    }
    return date
  }
}

/// Append-only JSONL trace sink. Opens, appends, flushes, closes per event via
/// `AtomicFile.appendJSONLine`; crash mid-write can corrupt at most the final
/// line. `readRecoveringEvents` skips that final torn line but fails on malformed
/// middle lines so data corruption is visible.
public actor JSONLTraceSink: TranscriptionSink {
  public static let currentSchemaVersion = 1

  private let url: URL
  private let source: String
  private let sourceKind: TraceSourceKind
  private let streamId: String
  private let locale: String
  private let preset: String
  private var nextEventId: Int
  private var writtenEvents: Int = 0
  private var droppedEvents: Int = 0
  private var lastErrorDescription: String?
  private let encoder: JSONEncoder

  public init(
    url: URL,
    source: String,
    sourceKind: TraceSourceKind,
    streamId: String = UUID().uuidString,
    locale: String,
    preset: String,
    startingEventId: Int = 1
  ) throws {
    self.url = url
    self.source = source
    self.sourceKind = sourceKind
    self.streamId = streamId
    self.locale = locale
    self.preset = preset
    self.nextEventId = startingEventId

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = TraceDateCoding.encodingStrategy
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder

    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    AtomicFile.ensureExists(url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.close()
  }

  @discardableResult
  public func record(
    eventKind: TraceEventKind,
    text: String,
    monotonicOffsetMs: Double,
    wallclock: Date = Date(),
    speakerId: String? = nil,
    audioRange: TraceAudioRange? = nil,
    audioSegmentPath: String? = nil,
    channelPolicy: String? = nil,
    exportPolicy: String? = nil
  ) -> TraceEvent {
    let event = TraceEvent(
      schemaVersion: Self.currentSchemaVersion,
      eventId: nextEventId,
      source: source,
      sourceKind: sourceKind,
      streamId: streamId,
      wallclock: wallclock,
      monotonicOffsetMs: monotonicOffsetMs,
      eventKind: eventKind,
      text: text,
      isFinal: eventKind == .final,
      locale: locale,
      preset: preset,
      speakerId: speakerId,
      audioRange: audioRange,
      audioSegmentPath: audioSegmentPath,
      channelPolicy: channelPolicy,
      exportPolicy: exportPolicy
    )
    do {
      try AtomicFile.appendJSONLine(event, to: url, encoder: encoder)
      nextEventId += 1
      writtenEvents += 1
    } catch {
      droppedEvents += 1
      lastErrorDescription = String(describing: error)
      FileHandle.standardError.write(Data("[ERROR] [trace] failed to append JSONL event to \(url.path): \(error)\n".utf8))
    }
    return event
  }

  public func stats() -> JSONLTraceSinkStats {
    JSONLTraceSinkStats(
      writtenEvents: writtenEvents,
      droppedEvents: droppedEvents,
      lastErrorDescription: lastErrorDescription
    )
  }

  public func didReceiveVolatile(_ text: String, wallclockOffsetMs: Double) async {
    record(eventKind: .volatile, text: text, monotonicOffsetMs: wallclockOffsetMs)
  }

  public func didReceiveFinal(_ text: String, wallclockOffsetMs: Double, wallclock: Date) async {
    record(eventKind: .final, text: text, monotonicOffsetMs: wallclockOffsetMs, wallclock: wallclock)
  }

  public func didReceiveResult(
    _ text: String,
    isFinal: Bool,
    wallclockOffsetMs: Double,
    wallclock: Date,
    audioRange: TraceAudioRange?,
    speakerId: String?
  ) async {
    record(
      eventKind: isFinal ? .final : .volatile,
      text: text,
      monotonicOffsetMs: wallclockOffsetMs,
      wallclock: wallclock,
      speakerId: speakerId,
      audioRange: audioRange
    )
  }

  public static func readRecoveringEvents(from url: URL) throws -> JSONLTraceReadResult {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return JSONLTraceReadResult(events: [], recoveredTrailingLine: false)
    }

    let contents = try String(contentsOf: url, encoding: .utf8)
    let hasTerminatingNewline = contents.hasSuffix("\n")
    let rawLines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let lines = rawLines.last == "" ? rawLines.dropLast() : ArraySlice(rawLines)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = TraceDateCoding.decodingStrategy

    var events: [TraceEvent] = []
    var recoveredTrailingLine = false
    for (index, line) in lines.enumerated() {
      if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
      do {
        let event = try decoder.decode(TraceEvent.self, from: Data(line.utf8))
        events.append(event)
      } catch {
        let isLastLine = index == lines.count - 1
        if isLastLine && !hasTerminatingNewline {
          recoveredTrailingLine = true
          break
        }
        throw JSONLTraceRecoveryError.malformedLine(url: url, line: index + 1, contents: line)
      }
    }

    return JSONLTraceReadResult(events: events, recoveredTrailingLine: recoveredTrailingLine)
  }
}
