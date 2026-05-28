import Foundation
import Testing
@testable import Chronicle

@Suite("DaemonEventLog")
struct DaemonEventLogTests {
  @Test("append writes required versioned envelope fields in sequence order")
  func appendWritesRequiredVersionedEnvelopeFieldsInSequenceOrder() throws {
    let url = try temporaryLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let epoch = DaemonEpoch(rawValue: "epoch-1")
    let log = DaemonEventLog(url: url, source: .sysaudio, epoch: epoch)

    let first = try log.append(
      stream: .control,
      type: "capture.starting",
      payload: ["lifecycle": .string("starting")],
      monotonicSeconds: 10,
      wallClock: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let second = try log.append(
      stream: .heartbeat,
      type: "heartbeat",
      payload: ["peak": .number(42)],
      monotonicSeconds: 11,
      wallClock: Date(timeIntervalSince1970: 1_700_000_002)
    )

    #expect(first.version == 1)
    #expect(first.sequence == 1)
    #expect(second.sequence == 2)
    #expect(first.epoch == epoch)
    #expect(first.source == .sysaudio)
    #expect(first.stream == .control)
    #expect(first.monotonicSeconds == 10)
    #expect(first.wallClock == Date(timeIntervalSince1970: 1_700_000_001))
    #expect(first.type == "capture.starting")
    #expect(first.payload["lifecycle"] == .string("starting"))

    let recovered = try DaemonEventLog.read(url: url)
    #expect(recovered == [first, second])
  }

  @Test("recovery event records a new epoch before normal events")
  func recoveryEventRecordsNewEpochBeforeNormalEvents() throws {
    let url = try temporaryLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let previous = DaemonEpoch(rawValue: "old-epoch")
    let current = DaemonEpoch(rawValue: "new-epoch")
    let log = DaemonEventLog(url: url, source: .mic, epoch: current)

    let recovery = try log.appendRecovery(
      previousEpoch: previous,
      reason: "unclean_exit",
      monotonicSeconds: 20,
      wallClock: Date(timeIntervalSince1970: 1_700_000_010)
    )
    _ = try log.append(stream: .control, type: "capture.starting", monotonicSeconds: 21)

    let events = try DaemonEventLog.read(url: url)
    #expect(events.first == recovery)
    #expect(events.first?.stream == .manifest)
    #expect(events.first?.type == "daemon.recovery")
    #expect(events.first?.epoch == current)
    #expect(events.first?.payload["previous_epoch"] == .string(previous.rawValue))
    #expect(events.first?.payload["reason"] == .string("unclean_exit"))
    #expect(events.map(\.sequence) == [1, 2])
  }

  @Test("reader ignores one torn trailing record")
  func readerIgnoresOneTornTrailingRecord() throws {
    let url = try temporaryLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = DaemonEventLog(url: url, source: .sysaudio, epoch: DaemonEpoch(rawValue: "epoch"))
    let complete = try log.append(stream: .control, type: "capture.started")
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"v":1,"seq":"#.utf8))
    try handle.close()

    let recovered = try DaemonEventLog.read(url: url)
    #expect(recovered == [complete])
  }

  @Test("reader fails on malformed middle record")
  func readerFailsOnMalformedMiddleRecord() throws {
    let url = try temporaryLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let good = DaemonEvent(
      version: 1,
      sequence: 1,
      epoch: DaemonEpoch(rawValue: "epoch"),
      source: .mic,
      stream: .control,
      monotonicSeconds: 1,
      wallClock: Date(timeIntervalSince1970: 1),
      type: "capture.started",
      payload: [:]
    )
    let encoder = DaemonEventLog.encoder()
    try String(data: encoder.encode(good), encoding: .utf8)!.write(to: url, atomically: true, encoding: .utf8)
    try AtomicFile.appendLine(#"{"v":1,"seq":"#, to: url)
    try AtomicFile.appendLine(String(data: encoder.encode(good.withSequence(3)), encoding: .utf8)!, to: url)

    #expect(throws: DaemonEventLogError.self) {
      _ = try DaemonEventLog.read(url: url)
    }
  }

  private func temporaryLogURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("chronicle-daemon-event-log-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("daemon.jsonl")
  }
}
