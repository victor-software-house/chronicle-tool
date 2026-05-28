import Foundation
import Testing
@testable import Chronicle

@Suite("DaemonCoordinator reconfiguration")
struct DaemonReconfigurationTests {
  @Test("progressive layer change keeps rough transcript capture active")
  func progressiveLayerChangeKeepsRoughTranscriptCaptureActive() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .mic, rootDirectory: try temporaryRoot()), configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure"))

    let result = await coordinator.reconfigure(.setDiarization(enabled: true), clientRequestID: ClientRequestID(rawValue: "reconfig-1"))

    #expect(result.outcome == .appliedLive)
    #expect(result.status.lifecycle == .capturing)
    #expect(result.status.roughTranscriptActive)
    #expect(result.error == nil)
    let events = await coordinator.controlEvents()
    #expect(events.contains { $0.type == "capture.reconfigure.started" })
    #expect(events.contains { $0.type == "capture.reconfigure.succeeded" })
  }

  @Test("unsafe active change is rejected with non retriable structured error and alternative")
  func unsafeActiveChangeIsRejectedWithNonRetriableStructuredErrorAndAlternative() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot()), configuration: .direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure"))

    let result = await coordinator.reconfigure(.setAudioFormat("wav"), clientRequestID: ClientRequestID(rawValue: "reconfig-2"))

    #expect(result.status.lifecycle == .capturing)
    #expect(result.error?.code == .invalidConfig)
    #expect(result.error?.retriable == false)
    #expect(result.error?.hint.contains("new segment") == true)
    let events = await coordinator.controlEvents()
    #expect(events.contains { $0.type == "capture.reconfigure.failed" })
  }

  @Test("same reconfigure client request id replays same outcome")
  func sameReconfigureClientRequestIDReplaysSameOutcome() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .mic, rootDirectory: try temporaryRoot()), configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure"))

    let first = await coordinator.reconfigure(.setDiarization(enabled: true), clientRequestID: ClientRequestID(rawValue: "same"))
    let second = await coordinator.reconfigure(.setAudioFormat("wav"), clientRequestID: ClientRequestID(rawValue: "same"))

    #expect(second == first)
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("crecfg-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
