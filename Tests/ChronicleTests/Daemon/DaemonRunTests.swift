import Foundation
import Testing
@testable import ChronicleCore

@Suite("Daemon run")
struct DaemonRunTests {
  @Test("start publishes socket pid and daemon.started control event")
  func startPublishesSocketPidAndDaemonStartedControlEvent() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = try makeDaemon(paths: paths)

    try await daemon.start()

    #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))
    #expect(FileManager.default.fileExists(atPath: paths.pidURL.path))
    let events = try DaemonEventLog.read(url: paths.logURL)
    #expect(events.contains { $0.type == "daemon.started" })

    await daemon.stop()
  }

  @Test("duplicate start rejects with alreadyOwned without recreating socket")
  func duplicateStartRejectsWithAlreadyOwnedWithoutRecreatingSocket() async throws {
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot())
    let first = try makeDaemon(paths: paths)
    try await first.start()
    let firstInode = inode(at: paths.socketURL)

    let second = try makeDaemon(paths: paths)
    do {
      try await second.start()
      Issue.record("expected duplicate start to throw")
    } catch let error as SourceOwnerError {
      guard case .alreadyOwned = error else {
        Issue.record("expected alreadyOwned error, got \(error)")
        return
      }
    }

    #expect(inode(at: paths.socketURL) == firstInode)
    await first.stop()
  }

  @Test("stop removes socket pid file and appends daemon.stopped event")
  func stopRemovesSocketPidFileAndAppendsDaemonStoppedEvent() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = try makeDaemon(paths: paths)
    try await daemon.start()

    await daemon.stop()

    #expect(!FileManager.default.fileExists(atPath: paths.socketURL.path))
    #expect(!FileManager.default.fileExists(atPath: paths.pidURL.path))
    let events = try DaemonEventLog.read(url: paths.logURL)
    #expect(events.contains { $0.type == "daemon.stopped" })
  }

  @Test("isRunning tracks start and stop")
  func isRunningTracksStartAndStop() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = try makeDaemon(paths: paths)
    #expect(await daemon.isRunning == false)
    try await daemon.start()
    #expect(await daemon.isRunning)
    await daemon.stop()
    #expect(await daemon.isRunning == false)
  }

  private func makeDaemon(paths: RuntimePaths) throws -> Daemon {
    Daemon(paths: paths, configuration: .direct(source: paths.source, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cdaem-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func inode(at url: URL) -> UInt64? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
  }
}
