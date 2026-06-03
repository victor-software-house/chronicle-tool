import Foundation
import Testing
@testable import ChronicleCore

@Suite("Control client commands")
struct ControlClientCommandsTests {
  @Test("status command returns coordinator-projected status against running daemon")
  func statusCommandReturnsCoordinatorProjectedStatusAgainstRunningDaemon() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await StatusClient.fetch(paths: paths)
    #expect(response.error == nil)
    #expect(response.result?["source"] == .string("mic"))
    #expect(response.result?["lifecycle"] == .string("stopped"))
    #expect(response.result?["health"] == .string("stopped"))
    if case .object(let sidecars)? = response.result?["sidecars"] {
      #expect(sidecars["socket"] != nil)
      #expect(sidecars["lock"] != nil)
      #expect(sidecars["pid"] != nil)
      #expect(sidecars["log"] != nil)
    } else {
      Issue.record("status result missing sidecars object")
    }
  }

  @Test("status command returns daemon_unavailable when no daemon running")
  func statusCommandReturnsDaemonUnavailableWhenNoDaemonRunning() async throws {
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot())

    let response = await StatusClient.fetch(paths: paths)

    #expect(response.error?.code == .daemonUnavailable)
    #expect(response.error?.retriable == true)
  }

  @Test("start command returns capturing lifecycle from coordinator ensure")
  func startCommandReturnsCapturingLifecycleFromCoordinatorEnsure() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "start-1"))

    #expect(response.error == nil)
    #expect(response.result?["source"] == .string("mic"))
    #expect(response.result?["lifecycle"] == .string("capturing"))
    if case .object(let status)? = response.result?["status"] {
      #expect(status["lifecycle"] == .string("capturing"))
    } else {
      Issue.record("ensure result missing status object")
    }
  }

  @Test("stop command returns already_stopped when capture was never started")
  func stopCommandReturnsAlreadyStoppedWhenCaptureWasNeverStarted() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await StopClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "stop-1"))

    #expect(response.error == nil)
    #expect(response.result?["source"] == .string("mic"))
    #expect(response.result?["lifecycle"] == .string("stopped"))
    #expect(response.result?["outcome"] == .string("already_stopped"))
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
