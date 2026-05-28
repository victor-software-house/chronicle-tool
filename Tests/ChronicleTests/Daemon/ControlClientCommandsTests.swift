import Foundation
import Testing
@testable import Chronicle

@Suite("Control client commands")
struct ControlClientCommandsTests {
  @Test("status command renders machine readable JSON against running daemon")
  func statusCommandRendersMachineReadableJSONAgainstRunningDaemon() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await StatusClient.fetch(paths: paths)
    #expect(response.error == nil)
    let json = response.encodedString()
    #expect(json.contains("\"source\":\"mic\""))
    #expect(json.contains("\"lifecycle\":\"stopped\""))
    #expect(json.contains("\"socket\":\"\(paths.socketURL.path)\""))
  }

  @Test("status command returns daemon_unavailable when no daemon running")
  func statusCommandReturnsDaemonUnavailableWhenNoDaemonRunning() async throws {
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot())

    let response = await StatusClient.fetch(paths: paths)

    #expect(response.error?.code == .daemonUnavailable)
    #expect(response.error?.retriable == true)
  }

  @Test("start command sends capture.ensure with client request id")
  func startCommandSendsCaptureEnsureWithClientRequestID() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "start-1"))

    #expect(response.error == nil)
    #expect(response.result?["accepted"] == .bool(true))
  }

  @Test("stop command sends capture.stop with client request id")
  func stopCommandSendsCaptureStopWithClientRequestID() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await StopClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "stop-1"))

    #expect(response.error == nil)
    #expect(response.result?["accepted"] == .bool(true))
  }

  private func directConfig(paths: RuntimePaths) -> LiveCaptureConfiguration {
    .direct(source: paths.source, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cctl-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
