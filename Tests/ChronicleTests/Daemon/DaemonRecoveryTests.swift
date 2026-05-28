import Foundation
import Testing
@testable import Chronicle

@Suite("Daemon recovery")
struct DaemonRecoveryTests {
  @Test("restart after crash appends daemon.recovery event")
  func restartAfterCrashAppendsDaemonRecoveryEvent() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let crashy = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await crashy.start()
    // Simulate hard kill: drop the lease without stopping the daemon (no daemon.stopped event).
    await crashy.simulateHardKill()

    let restarted = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await restarted.start()
    defer { Task { await restarted.stop() } }

    let events = try DaemonEventLog.read(url: paths.logURL)
    #expect(events.contains { $0.type == "daemon.recovery" })
    #expect(events.last?.type == "daemon.started")
  }

  @Test("clean shutdown does not append recovery on next start")
  func cleanShutdownDoesNotAppendRecoveryOnNextStart() async throws {
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot())
    let first = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await first.start()
    await first.stop()

    let second = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await second.start()
    defer { Task { await second.stop() } }

    let events = try DaemonEventLog.read(url: paths.logURL)
    #expect(!events.contains { $0.type == "daemon.recovery" })
  }

  private func directConfig(paths: RuntimePaths) -> LiveCaptureConfiguration {
    .direct(source: paths.source, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("crec-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
