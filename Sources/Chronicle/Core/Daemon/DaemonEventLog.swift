import Foundation

public enum DaemonEventLogError: Error, Equatable, CustomStringConvertible, Sendable {
  case malformedRecord(line: Int, reason: String)

  public var description: String {
    switch self {
    case .malformedRecord(let line, let reason):
      "malformed daemon event log record at line \(line): \(reason)"
    }
  }
}

/// Append/read helper for daemon-owned JSONL event logs.
///
/// Uses `AtomicFile.appendJSONLine`, preserving the existing O_APPEND + flock
/// durability contract. A hard kill can invalidate at most the final line; the
/// reader ignores one malformed trailing record and rejects malformed middle
/// records.
public struct DaemonEventLog: Sendable {
  public let url: URL
  public let source: CaptureSource
  public let epoch: DaemonEpoch
  private var nextSequence: Int

  public init(url: URL, source: CaptureSource, epoch: DaemonEpoch, nextSequence: Int = 1) {
    self.url = url
    self.source = source
    self.epoch = epoch
    self.nextSequence = nextSequence
  }

  @discardableResult
  public mutating func append(
    stream: DaemonEventStream,
    type: String,
    payload: [String: JSONValue] = [:],
    monotonicSeconds: Double = ProcessInfo.processInfo.systemUptime,
    wallClock: Date = Date()
  ) throws -> DaemonEvent {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let event = DaemonEvent(
      sequence: nextSequence,
      epoch: epoch,
      source: source,
      stream: stream,
      monotonicSeconds: monotonicSeconds,
      wallClock: wallClock,
      type: type,
      payload: payload
    )
    try AtomicFile.appendJSONLine(event, to: url, encoder: Self.encoder())
    nextSequence += 1
    return event
  }

  @discardableResult
  public mutating func appendRecovery(
    previousEpoch: DaemonEpoch,
    reason: String,
    monotonicSeconds: Double = ProcessInfo.processInfo.systemUptime,
    wallClock: Date = Date()
  ) throws -> DaemonEvent {
    try append(
      stream: .manifest,
      type: "daemon.recovery",
      payload: [
        "previous_epoch": .string(previousEpoch.rawValue),
        "reason": .string(reason),
      ],
      monotonicSeconds: monotonicSeconds,
      wallClock: wallClock
    )
  }

  public static func read(url: URL) throws -> [DaemonEvent] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let contents = try String(contentsOf: url, encoding: .utf8)
    guard !contents.isEmpty else { return [] }

    let rawLines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let lines = rawLines.last == "" ? rawLines.dropLast() : ArraySlice(rawLines)
    var events: [DaemonEvent] = []
    let decoder = Self.decoder()

    for (offset, line) in lines.enumerated() {
      guard let data = line.data(using: .utf8) else {
        throw DaemonEventLogError.malformedRecord(line: offset + 1, reason: "line is not utf8")
      }
      do {
        events.append(try decoder.decode(DaemonEvent.self, from: data))
      } catch {
        if offset == lines.count - 1 {
          return events
        }
        throw DaemonEventLogError.malformedRecord(line: offset + 1, reason: error.localizedDescription)
      }
    }

    return events
  }

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    JSONDecoder()
  }
}
