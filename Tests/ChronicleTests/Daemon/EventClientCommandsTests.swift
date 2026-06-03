import Foundation
import Testing
@testable import ChronicleCore

@Suite("Event client commands")
struct EventClientCommandsTests {
  @Test("mark client surfaces daemon_unavailable when no daemon running")
  func markClientSurfacesDaemonUnavailableWhenNoDaemonRunning() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let response = await MarkClient.send(paths: paths, label: "x", clientRequestID: ClientRequestID(rawValue: "m"))
    #expect(response.error?.code == .daemonUnavailable)
  }

  @Test("clip client serializes last_seconds and output path")
  func clipClientSerializesLastSecondsAndOutputPath() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let request = TailRequest(source: paths.source, streams: [.control, .heartbeat], typePrefix: "capture.", sinceSequence: 5, includeHeartbeat: false)
    let rpc = request.rpcRequest(id: .string("t"))
    #expect(rpc.method == "events.subscribe")
    #expect(rpc.params?["streams"] == .string("control,heartbeat"))
    #expect(rpc.params?["type_prefix"] == .string("capture."))
    #expect(rpc.params?["since_sequence"] == .number(5))
    #expect(rpc.params?["include_heartbeat"] == .bool(false))
  }

  @Test("config client serializes capture.reconfigure with change payload")
  func configClientSerializesCaptureReconfigureWithChangePayload() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let response = await ConfigClient.send(paths: paths, change: .setDiarization(enabled: true), clientRequestID: ClientRequestID(rawValue: "c"))
    #expect(response.error?.code == .daemonUnavailable)
  }

  @Test("tail client returns response and renders JSONL line")
  func tailClientReturnsResponseAndRendersJSONLLine() async throws {
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: .direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await TailClient.send(paths: paths, request: TailRequest(source: .sysaudio))
    #expect(response.error == nil)

    let event = DaemonEvent(sequence: 1, epoch: DaemonEpoch(rawValue: "e"), source: .sysaudio, stream: .control, monotonicSeconds: 0, wallClock: Date(timeIntervalSince1970: 0), type: "capture.started")
    let line = TailClient.renderEventLine(event)
    #expect(line.contains("\"seq\":1"))
    #expect(line.contains("\"type\":\"capture.started\""))
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cevt-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
