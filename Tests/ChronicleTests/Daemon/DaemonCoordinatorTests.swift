import Foundation
import Testing
@testable import Chronicle

@Suite("DaemonCoordinator")
struct DaemonCoordinatorTests {
  @Test("ensure when stopped acquires owner and starts session")
  func ensureWhenStoppedAcquiresOwnerAndStartsSession() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .mic, rootDirectory: try temporaryRoot()), configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))

    let result = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure-1"))
    #expect(result.source == .mic)
    #expect(result.lifecycle == .capturing)
    #expect(result.existingOwner == nil)
  }

  @Test("ensure when already running returns existing running state")
  func ensureWhenAlreadyRunningReturnsExistingRunningState() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot()), configuration: .direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))

    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure-1"))
    let duplicate = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure-2"))

    #expect(duplicate.lifecycle == .capturing)
    #expect(duplicate.existingOwner?.isActive == true)
    #expect(duplicate.existingOwner?.source == .sysaudio)
  }

  @Test("same ensure client request id replays same outcome")
  func sameEnsureClientRequestIDReplaysSameOutcome() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .mic, rootDirectory: try temporaryRoot()), configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))

    let first = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure-replay"))
    let replay = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure-replay"))

    #expect(replay == first)
  }

  @Test("status when stopped returns stopped state")
  func statusWhenStoppedReturnsStoppedState() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot()), configuration: .direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))

    let status = await coordinator.status()
    #expect(status.lifecycle == .stopped)
    #expect(status.source == .sysaudio)
  }

  @Test("stop when stopped is idempotent")
  func stopWhenStoppedIsIdempotent() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .mic, rootDirectory: try temporaryRoot()), configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))

    let stopped = await coordinator.stop(clientRequestID: ClientRequestID(rawValue: "stop-1"))
    #expect(stopped.lifecycle == .stopped)
    #expect(stopped.outcome == .alreadyStopped)
  }

  @Test("stop running session releases owner and reports graceful stop")
  func stopRunningSessionReleasesOwnerAndReportsGracefulStop() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let coordinator = DaemonCoordinator(paths: paths, configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure-1"))

    let stopped = await coordinator.stop(clientRequestID: ClientRequestID(rawValue: "stop-1"))
    #expect(stopped.lifecycle == .stopped)
    #expect(stopped.outcome == .graceful)
    #expect(SourceOwner(paths: paths).inspect().lifecycle == .stopped)
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cco-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
