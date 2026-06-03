import Foundation
import Testing
@testable import ChronicleCore

@Suite("DaemonStatus")
struct DaemonStatusTests {
  @Test("stopped snapshot succeeds without heartbeat")
  func stoppedSnapshotSucceedsWithoutHeartbeat() {
    let paths = RuntimePaths(source: .mic, rootDirectory: URL(fileURLWithPath: "/tmp/chronicle-status", isDirectory: true))
    let status = DaemonStatus.stopped(source: .mic, paths: paths)

    #expect(status.source == .mic)
    #expect(status.lifecycle == .stopped)
    #expect(status.sidecars.socket == paths.socketURL)
    #expect(status.lastHeartbeat == nil)
    #expect(status.lastActionableError == nil)
  }

  @Test("fresh heartbeat with runtime evidence projects capturing healthy state")
  func freshHeartbeatWithRuntimeEvidenceProjectsCapturingHealthyState() {
    let now = Date(timeIntervalSince1970: 100)
    let status = DaemonStatus.project(
      source: .sysaudio,
      paths: RuntimePaths(source: .sysaudio, rootDirectory: URL(fileURLWithPath: "/tmp/chronicle-status", isDirectory: true)),
      heartbeat: Heartbeat(source: .sysaudio, lifecycle: .capturing, at: Date(timeIntervalSince1970: 95), peak: 128, transcriptFinalCount: 2, transcriptVolatileCount: 5, speakerLabelState: .available(labelCount: 2), idleOutput: false),
      freshnessTTL: 10,
      now: now
    )

    #expect(status.lifecycle == .capturing)
    #expect(status.health == .healthy)
    #expect(status.lastObservedPeak == 128)
    #expect(status.transcriptCounters.final == 2)
    #expect(status.transcriptCounters.volatile == 5)
    #expect(status.speakerLabelState == .available(labelCount: 2))
  }

  @Test("expired heartbeat projects stale state")
  func expiredHeartbeatProjectsStaleState() {
    let now = Date(timeIntervalSince1970: 100)
    let status = DaemonStatus.project(
      source: .mic,
      paths: RuntimePaths(source: .mic, rootDirectory: URL(fileURLWithPath: "/tmp/chronicle-status", isDirectory: true)),
      heartbeat: Heartbeat(source: .mic, lifecycle: .capturing, at: Date(timeIntervalSince1970: 70), peak: 50, transcriptFinalCount: 1, transcriptVolatileCount: 1, speakerLabelState: .warming, idleOutput: false),
      freshnessTTL: 10,
      now: now
    )

    #expect(status.lifecycle == .stale)
    #expect(status.health == .stale)
    #expect(status.lastActionableError?.code == "heartbeat_stale")
  }

  @Test("idle output is separate from capture failure")
  func idleOutputIsSeparateFromCaptureFailure() {
    let now = Date(timeIntervalSince1970: 100)
    let status = DaemonStatus.project(
      source: .sysaudio,
      paths: RuntimePaths(source: .sysaudio, rootDirectory: URL(fileURLWithPath: "/tmp/chronicle-status", isDirectory: true)),
      heartbeat: Heartbeat(source: .sysaudio, lifecycle: .capturing, at: now, peak: 0, transcriptFinalCount: 0, transcriptVolatileCount: 0, speakerLabelState: .unavailable, idleOutput: true),
      freshnessTTL: 10,
      now: now
    )

    #expect(status.lifecycle == .capturing)
    #expect(status.health == .idleOutput)
    #expect(status.lastActionableError == nil)
  }

  @Test("progressive layer failure projects degraded without source failure")
  func progressiveLayerFailureProjectsDegradedWithoutSourceFailure() {
    let now = Date(timeIntervalSince1970: 100)
    let status = DaemonStatus.project(
      source: .mic,
      paths: RuntimePaths(source: .mic, rootDirectory: URL(fileURLWithPath: "/tmp/chronicle-status", isDirectory: true)),
      heartbeat: Heartbeat(source: .mic, lifecycle: .degraded, at: now, peak: 16, transcriptFinalCount: 1, transcriptVolatileCount: 1, speakerLabelState: .failed(reason: "sortformer"), idleOutput: false),
      freshnessTTL: 10,
      now: now
    )

    #expect(status.lifecycle == .degraded)
    #expect(status.health == .degraded)
    #expect(status.speakerLabelState == .failed(reason: "sortformer"))
    #expect(status.lastActionableError?.code == "progressive_layer_failed")
  }
}
