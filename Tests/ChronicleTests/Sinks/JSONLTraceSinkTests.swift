import Foundation
import Testing
@testable import Chronicle

@Suite("JSONLTraceSink")
struct JSONLTraceSinkTests {
  private func tmpDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("JSONLTraceSinkTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func readRawObjects(from url: URL) throws -> [[String: Any]] {
    let lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    return try lines.map { line in
      try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      )
    }
  }

  @Test("appends valid source-aware volatile and final JSONL events")
  func appendsValidSourceAwareEvents() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let traceURL = dir.appendingPathComponent("trace.jsonl")

    let sink = try JSONLTraceSink(
      url: traceURL,
      source: "mic",
      sourceKind: .microphone,
      streamId: "stream-1",
      locale: "en-US",
      preset: "progressiveTranscription"
    )

    await sink.didReceiveVolatile("hello", wallclockOffsetMs: 125.5)
    await sink.didReceiveFinal(
      "hello world",
      wallclockOffsetMs: 250.25,
      wallclock: Date(timeIntervalSince1970: 1_700_000_000.123)
    )

    let objects = try readRawObjects(from: traceURL)
    #expect(objects.count == 2)
    #expect(objects[0]["schemaVersion"] as? Int == 1)
    #expect(objects[0]["eventId"] as? Int == 1)
    #expect(objects[0]["source"] as? String == "mic")
    #expect(objects[0]["sourceKind"] as? String == "microphone")
    #expect(objects[0]["streamId"] as? String == "stream-1")
    #expect(objects[0]["eventKind"] as? String == "volatile")
    #expect(objects[0]["isFinal"] as? Bool == false)
    #expect(objects[0]["text"] as? String == "hello")
    #expect(objects[0]["locale"] as? String == "en-US")
    #expect(objects[0]["preset"] as? String == "progressiveTranscription")
    #expect(objects[0]["monotonicOffsetMs"] as? Double == 125.5)

    #expect(objects[1]["eventId"] as? Int == 2)
    #expect(objects[1]["eventKind"] as? String == "final")
    #expect(objects[1]["isFinal"] as? Bool == true)
    #expect(objects[1]["text"] as? String == "hello world")
    #expect((objects[1]["wallclock"] as? String)?.contains(".") == true)

    let stats = await sink.stats()
    #expect(stats.writtenEvents == 2)
    #expect(stats.droppedEvents == 0)
    #expect(stats.lastErrorDescription == nil)
  }

  @Test("records sysaudio source metadata")
  func recordsSysAudioSourceMetadata() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let traceURL = dir.appendingPathComponent("trace.jsonl")

    let sink = try JSONLTraceSink(
      url: traceURL,
      source: "sysaudio",
      sourceKind: .systemOutput,
      streamId: "sys-stream",
      locale: "en-US",
      preset: "progressiveTranscription"
    )
    await sink.didReceiveFinal(
      "system output words",
      wallclockOffsetMs: 50,
      wallclock: Date(timeIntervalSince1970: 1_700_000_001)
    )

    let event = try #require(try JSONLTraceSink.readRecoveringEvents(from: traceURL).events.first)
    #expect(event.source == "sysaudio")
    #expect(event.sourceKind == .systemOutput)
    #expect(event.streamId == "sys-stream")
    #expect(event.locale == "en-US")
    #expect(event.isFinal)
  }

  @Test("recovers by skipping one torn trailing line")
  func recoversTornTrailingLine() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let traceURL = dir.appendingPathComponent("trace.jsonl")

    let sink = try JSONLTraceSink(
      url: traceURL,
      source: "mic",
      sourceKind: .microphone,
      streamId: "stream-1",
      locale: "en-US",
      preset: "progressiveTranscription"
    )
    await sink.didReceiveFinal(
      "complete",
      wallclockOffsetMs: 100,
      wallclock: Date(timeIntervalSince1970: 1_700_000_002)
    )
    try AtomicFile.appendLine("{\"schemaVersion\":1,\"eventId\":", to: traceURL)

    var data = try Data(contentsOf: traceURL)
    while data.last == UInt8(ascii: "\n") { data.removeLast() }
    try data.write(to: traceURL)

    let result = try JSONLTraceSink.readRecoveringEvents(from: traceURL)
    #expect(result.events.map(\.text) == ["complete"])
    #expect(result.recoveredTrailingLine)
  }

  @Test("throws on malformed middle line")
  func throwsOnMalformedMiddleLine() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let traceURL = dir.appendingPathComponent("trace.jsonl")

    let sink = try JSONLTraceSink(
      url: traceURL,
      source: "mic",
      sourceKind: .microphone,
      streamId: "stream-1",
      locale: "en-US",
      preset: "progressiveTranscription"
    )
    await sink.didReceiveFinal(
      "before",
      wallclockOffsetMs: 100,
      wallclock: Date(timeIntervalSince1970: 1_700_000_003)
    )
    try AtomicFile.appendLine("not-json", to: traceURL)
    await sink.didReceiveFinal(
      "after",
      wallclockOffsetMs: 200,
      wallclock: Date(timeIntervalSince1970: 1_700_000_004)
    )

    #expect(throws: JSONLTraceRecoveryError.self) {
      _ = try JSONLTraceSink.readRecoveringEvents(from: traceURL)
    }
  }

  @Test("direct record preserves audio range and ordering")
  func directRecordPreservesAudioRangeAndOrdering() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let traceURL = dir.appendingPathComponent("trace.jsonl")

    let sink = try JSONLTraceSink(
      url: traceURL,
      source: "live",
      sourceKind: .file,
      streamId: "file-stream",
      locale: "en-US",
      preset: "progressiveTranscription"
    )
    await sink.record(
      eventKind: .volatile,
      text: "partial",
      monotonicOffsetMs: 10,
      wallclock: Date(timeIntervalSince1970: 1_700_000_005),
      audioRange: TraceAudioRange(startSeconds: 1.25, endSeconds: 2.5)
    )
    await sink.record(
      eventKind: .final,
      text: "final",
      monotonicOffsetMs: 20,
      wallclock: Date(timeIntervalSince1970: 1_700_000_006),
      audioRange: TraceAudioRange(startSeconds: 2.5, endSeconds: 3.75)
    )

    let result = try JSONLTraceSink.readRecoveringEvents(from: traceURL)
    #expect(result.events.map(\.eventId) == [1, 2])
    #expect(result.events.map(\.eventKind) == [.volatile, .final])
    #expect(result.events[0].audioRange == TraceAudioRange(startSeconds: 1.25, endSeconds: 2.5))
    #expect(!result.recoveredTrailingLine)
  }

  @Test("concurrent sinks sharing one path produce readable JSONL")
  func concurrentSinksSharingPathProduceReadableJSONL() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let traceURL = dir.appendingPathComponent("trace.jsonl")

    let micSink = try JSONLTraceSink(
      url: traceURL,
      source: "mic",
      sourceKind: .microphone,
      streamId: "mic-stream",
      locale: "en-US",
      preset: "progressiveTranscription"
    )
    let sysSink = try JSONLTraceSink(
      url: traceURL,
      source: "sysaudio",
      sourceKind: .systemOutput,
      streamId: "sys-stream",
      locale: "en-US",
      preset: "progressiveTranscription"
    )

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for i in 0..<50 {
          await micSink.record(
            eventKind: .final,
            text: "mic event \(i)",
            monotonicOffsetMs: Double(i),
            wallclock: Date(timeIntervalSince1970: 1_700_001_000 + Double(i))
          )
        }
      }
      group.addTask {
        for i in 0..<50 {
          await sysSink.record(
            eventKind: .final,
            text: "sys event \(i)",
            monotonicOffsetMs: Double(i),
            wallclock: Date(timeIntervalSince1970: 1_700_002_000 + Double(i))
          )
        }
      }
    }

    let result = try JSONLTraceSink.readRecoveringEvents(from: traceURL)
    #expect(result.events.count == 100)
    #expect(result.events.filter { $0.source == "mic" }.count == 50)
    #expect(result.events.filter { $0.source == "sysaudio" }.count == 50)
    #expect(!result.recoveredTrailingLine)
  }
}
