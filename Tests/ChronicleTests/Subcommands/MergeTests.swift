import Foundation
import Testing
@testable import Chronicle

@Suite("Merge")
struct MergeTests {
  private func tmpDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("MergeTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: - Tests

  @Test("sorts JSONL events chronologically across two source files")
  func sortsTwoJSONLInputsChronologically() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let micURL = dir.appendingPathComponent("trace.mic.jsonl")
    let sysURL = dir.appendingPathComponent("trace.sys.jsonl")

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    try await appendFinal(
      to: micURL,
      source: "mic",
      sourceKind: .microphone,
      streamId: "mic-1",
      texts: [
        ("mic at +0.0s", base),
        ("mic at +2.0s", base.addingTimeInterval(2.0))
      ],
      locale: "en-US"
    )
    try await appendFinal(
      to: sysURL,
      source: "sysaudio",
      sourceKind: .systemOutput,
      streamId: "sys-1",
      texts: [
        ("sys at +1.0s", base.addingTimeInterval(1.0)),
        ("sys at +3.0s", base.addingTimeInterval(3.0))
      ],
      locale: "en-US"
    )

    let service = MergeService(includeVolatile: false, aliasMap: [:])
    let outcome = try service.loadAndSortRecords(inputs: [micURL, sysURL])

    #expect(outcome.records.count == 4)
    #expect(outcome.records.map(\.text) == [
      "mic at +0.0s",
      "sys at +1.0s",
      "mic at +2.0s",
      "sys at +3.0s"
    ])
    #expect(outcome.records.map(\.source) == ["mic", "sysaudio", "mic", "sysaudio"])
    #expect(outcome.warnings.isEmpty)
  }

  @Test("excludes volatile events by default; --include-volatile keeps them")
  func volatileEventsHonorIncludeFlag() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("trace.jsonl")

    let sink = try JSONLTraceSink(
      url: url,
      source: "mic",
      sourceKind: .microphone,
      streamId: "stream-1",
      locale: "en-US",
      preset: "progressiveTranscription"
    )
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    await sink.recordSync(eventKind: .volatile, text: "vol-1", wallclock: base)
    await sink.recordSync(eventKind: .final, text: "fin-1", wallclock: base.addingTimeInterval(0.1))
    await sink.recordSync(eventKind: .volatile, text: "vol-2", wallclock: base.addingTimeInterval(0.2))
    await sink.recordSync(eventKind: .final, text: "fin-2", wallclock: base.addingTimeInterval(0.3))

    let finalsOnly = try MergeService(includeVolatile: false, aliasMap: [:])
      .loadAndSortRecords(inputs: [url])
    #expect(finalsOnly.records.map(\.text) == ["fin-1", "fin-2"])

    let withVolatile = try MergeService(includeVolatile: true, aliasMap: [:])
      .loadAndSortRecords(inputs: [url])
    #expect(withVolatile.records.map(\.text) == ["vol-1", "fin-1", "vol-2", "fin-2"])
  }

  @Test("merges finals.md inputs with inferred sources")
  func mergesFinalsMarkdownInputs() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let micURL = dir.appendingPathComponent("finals.mic.md")
    let sysURL = dir.appendingPathComponent("finals.sysaudio.md")

    try """
    [2026-05-17T10:00:00.500Z] mic line A
    [2026-05-17T10:00:02.500Z] mic line B
    """.write(to: micURL, atomically: true, encoding: .utf8)
    try """
    [2026-05-17T10:00:01.500Z] sys line A
    [2026-05-17T10:00:03.500Z] sys line B
    """.write(to: sysURL, atomically: true, encoding: .utf8)

    let outcome = try MergeService(includeVolatile: false, aliasMap: [:])
      .loadAndSortRecords(inputs: [micURL, sysURL])

    #expect(outcome.records.count == 4)
    #expect(outcome.records.map(\.text) == [
      "mic line A",
      "sys line A",
      "mic line B",
      "sys line B"
    ])
    #expect(outcome.records.map(\.source) == ["mic", "sysaudio", "mic", "sysaudio"])
  }

  @Test("mixes JSONL trace with legacy finals.md fallback")
  func mixesJSONLWithFinalsMarkdown() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let micJSONL = dir.appendingPathComponent("trace.mic.jsonl")
    let legacyFinals = dir.appendingPathComponent("legacy-finals.md")

    let base = Date(timeIntervalSince1970: 1_700_000_010)
    try await appendFinal(
      to: micJSONL,
      source: "mic",
      sourceKind: .microphone,
      streamId: "mic-mix",
      texts: [
        ("mic-jsonl-1", base.addingTimeInterval(1)),
        ("mic-jsonl-2", base.addingTimeInterval(3))
      ],
      locale: "en-US"
    )
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp0 = formatter.string(from: base.addingTimeInterval(0))
    let stamp2 = formatter.string(from: base.addingTimeInterval(2))
    try """
    [\(stamp0)] legacy A
    [\(stamp2)] legacy B
    """.write(to: legacyFinals, atomically: true, encoding: .utf8)

    let aliases = try MergeService.parseAliasMap(["\(legacyFinals.path)=legacy"])
    let outcome = try MergeService(includeVolatile: false, aliasMap: aliases)
      .loadAndSortRecords(inputs: [micJSONL, legacyFinals])

    #expect(outcome.records.count == 4)
    #expect(outcome.records.map(\.text) == [
      "legacy A",
      "mic-jsonl-1",
      "legacy B",
      "mic-jsonl-2"
    ])
    #expect(outcome.records.map(\.source) == ["legacy", "mic", "legacy", "mic"])
  }

  @Test("preserves speaker labels from JSONL")
  func preservesSpeakerLabels() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("trace.jsonl")
    let base = Date(timeIntervalSince1970: 1_700_000_020)
    try await appendFinal(
      to: url,
      source: "mic",
      sourceKind: .microphone,
      streamId: "spk-stream",
      texts: [
        ("hello", base, "S1"),
        ("world", base.addingTimeInterval(1), "S2")
      ],
      locale: "en-US"
    )

    let outcome = try MergeService(includeVolatile: false, aliasMap: [:])
      .loadAndSortRecords(inputs: [url])
    #expect(outcome.records.map { $0.speakerId } == ["S1", "S2"])

    let log = MergeRenderer.render(records: outcome.records, format: .log)
    #expect(log.contains("(S1, en-US) hello"))
    #expect(log.contains("(S2, en-US) world"))
  }

  @Test("stable tie-break on identical wallclock uses source path then eventId")
  func stableTieBreakOnIdenticalWallclock() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let aURL = dir.appendingPathComponent("a.jsonl")
    let bURL = dir.appendingPathComponent("b.jsonl")

    let stamp = Date(timeIntervalSince1970: 1_700_000_100)
    try await appendFinal(
      to: aURL,
      source: "mic",
      sourceKind: .microphone,
      streamId: "a",
      texts: [
        ("a-first", stamp),
        ("a-second", stamp)
      ],
      locale: "en-US"
    )
    try await appendFinal(
      to: bURL,
      source: "sysaudio",
      sourceKind: .systemOutput,
      streamId: "b",
      texts: [
        ("b-first", stamp),
        ("b-second", stamp)
      ],
      locale: "en-US"
    )

    let outcome = try MergeService(includeVolatile: false, aliasMap: [:])
      .loadAndSortRecords(inputs: [aURL, bURL])
    // a.path < b.path alphabetically, so all a-* come first; within
    // each file, eventId ordering preserves write order.
    #expect(outcome.records.map(\.text) == ["a-first", "a-second", "b-first", "b-second"])
  }

  @Test("renders the log format with literal '[source]' prefix")
  func rendersLogFormatWithSourcePrefix() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let micURL = dir.appendingPathComponent("finals.mic.md")
    let sysURL = dir.appendingPathComponent("finals.sysaudio.md")

    try "[2026-05-17T10:00:00.500Z] hello mic\n".write(to: micURL, atomically: true, encoding: .utf8)
    try "[2026-05-17T10:00:01.500Z] hello sys\n".write(to: sysURL, atomically: true, encoding: .utf8)

    let outcome = try MergeService(includeVolatile: false, aliasMap: [:])
      .loadAndSortRecords(inputs: [micURL, sysURL])
    let rendered = MergeRenderer.render(records: outcome.records, format: .log)

    let lines = rendered.split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines[0].contains("[mic] hello mic"))
    #expect(lines[1].contains("[sysaudio] hello sys"))
    #expect(lines[0].hasPrefix("[2026-05-17T10:00:00.500Z]"))
  }

  @Test("renders the markdown table format with header and rows")
  func rendersMarkdownTableFormat() async throws {
    let stamp = Date(timeIntervalSince1970: 1_700_000_200)
    let records = [
      MergedRecord(
        wallclock: stamp,
        source: "mic",
        speakerId: "S1",
        locale: "en-US",
        text: "hello",
        sourcePath: "/tmp/a.jsonl",
        eventId: 1
      ),
      MergedRecord(
        wallclock: stamp.addingTimeInterval(1),
        source: "sysaudio",
        speakerId: nil,
        locale: nil,
        text: "with | pipe",
        sourcePath: "/tmp/b.jsonl",
        eventId: 2
      )
    ]

    let rendered = MergeRenderer.render(records: records, format: .markdown)
    let lines = rendered.split(separator: "\n").map(String.init)
    #expect(lines[0] == "| wallclock | source | speaker | locale | text |")
    #expect(lines[1] == "|---|---|---|---|---|")
    #expect(lines[2].contains("| mic | S1 | en-US | hello |"))
    #expect(lines[3].contains("| sysaudio |  |  | with \\| pipe |"))
  }

  @Test("recovers from torn trailing line and reports a warning")
  func recoversTornTrailingLineAndWarns() async throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("trace.jsonl")
    let base = Date(timeIntervalSince1970: 1_700_000_300)
    try await appendFinal(
      to: url,
      source: "mic",
      sourceKind: .microphone,
      streamId: "torn",
      texts: [
        ("intact", base)
      ],
      locale: "en-US"
    )
    // Append a torn (no-newline, malformed) trailing line.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    handle.write(Data("{\"schemaVersion\":1,\"eventId\":2,\"source\":\"".utf8))
    try handle.close()

    let outcome = try MergeService(includeVolatile: false, aliasMap: [:])
      .loadAndSortRecords(inputs: [url])
    #expect(outcome.records.map(\.text) == ["intact"])
    #expect(outcome.warnings.contains { $0.contains("recovered torn trailing line") })
  }

  @Test("rejects --source-alias without an '=' separator")
  func rejectsAliasWithoutSeparator() throws {
    do {
      _ = try MergeService.parseAliasMap(["only-name"])
      Issue.record("expected parseAliasMap to throw on missing '='.")
    } catch {
      #expect(String(describing: error).lowercased().contains("source-alias"))
    }
  }

  // MARK: - Helpers

  private func appendFinal(
    to url: URL,
    source: String,
    sourceKind: TraceSourceKind,
    streamId: String,
    texts: [(String, Date)],
    locale: String
  ) async throws {
    let sink = try JSONLTraceSink(
      url: url,
      source: source,
      sourceKind: sourceKind,
      streamId: streamId,
      locale: locale,
      preset: "progressiveTranscription"
    )
    for (text, wallclock) in texts {
      await sink.recordSync(eventKind: .final, text: text, wallclock: wallclock)
    }
  }

  private func appendFinal(
    to url: URL,
    source: String,
    sourceKind: TraceSourceKind,
    streamId: String,
    texts: [(String, Date, String?)],
    locale: String
  ) async throws {
    let sink = try JSONLTraceSink(
      url: url,
      source: source,
      sourceKind: sourceKind,
      streamId: streamId,
      locale: locale,
      preset: "progressiveTranscription"
    )
    for (text, wallclock, speakerId) in texts {
      await sink.recordSync(
        eventKind: .final,
        text: text,
        wallclock: wallclock,
        speakerId: speakerId
      )
    }
  }
}

// Bridge `record(...)` (synchronous on the actor) so tests can await with
// `recordSync(...)` for readability.
extension JSONLTraceSink {
  func recordSync(
    eventKind: TraceEventKind,
    text: String,
    wallclock: Date,
    speakerId: String? = nil
  ) {
    record(
      eventKind: eventKind,
      text: text,
      monotonicOffsetMs: 0,
      wallclock: wallclock,
      speakerId: speakerId
    )
  }
}
