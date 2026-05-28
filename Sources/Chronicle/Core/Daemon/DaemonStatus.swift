import Foundation

public struct Heartbeat: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let lifecycle: DaemonLifecycle
  public let at: Date
  public let peak: Int
  public let transcriptFinalCount: Int
  public let transcriptVolatileCount: Int
  public let speakerLabelState: SpeakerLabelState
  public let idleOutput: Bool

  public init(
    source: CaptureSource,
    lifecycle: DaemonLifecycle,
    at: Date,
    peak: Int,
    transcriptFinalCount: Int,
    transcriptVolatileCount: Int,
    speakerLabelState: SpeakerLabelState,
    idleOutput: Bool
  ) {
    self.source = source
    self.lifecycle = lifecycle
    self.at = at
    self.peak = peak
    self.transcriptFinalCount = transcriptFinalCount
    self.transcriptVolatileCount = transcriptVolatileCount
    self.speakerLabelState = speakerLabelState
    self.idleOutput = idleOutput
  }
}

public enum SpeakerLabelState: Codable, Equatable, Sendable {
  case unavailable
  case warming
  case available(labelCount: Int)
  case failed(reason: String)
}

public enum DaemonHealth: String, Codable, Equatable, Sendable {
  case stopped
  case healthy
  case idleOutput
  case degraded
  case stale
  case failed
}

public struct TranscriptCounters: Codable, Equatable, Sendable {
  public let final: Int
  public let volatile: Int
}

public struct DaemonSidecarPaths: Codable, Equatable, Sendable {
  public let socket: URL
  public let lock: URL
  public let pid: URL
  public let log: URL
}

public struct ActionableError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String
  public let remediation: String
}

public struct DaemonStatus: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let lifecycle: DaemonLifecycle
  public let health: DaemonHealth
  public let sidecars: DaemonSidecarPaths
  public let lastHeartbeat: Date?
  public let lastObservedPeak: Int?
  public let transcriptCounters: TranscriptCounters
  public let speakerLabelState: SpeakerLabelState
  public let idleOutput: Bool
  public let lastActionableError: ActionableError?

  public static func stopped(source: CaptureSource, paths: RuntimePaths) -> DaemonStatus {
    DaemonStatus(
      source: source,
      lifecycle: .stopped,
      health: .stopped,
      sidecars: DaemonSidecarPaths(paths: paths),
      lastHeartbeat: nil,
      lastObservedPeak: nil,
      transcriptCounters: TranscriptCounters(final: 0, volatile: 0),
      speakerLabelState: .unavailable,
      idleOutput: false,
      lastActionableError: nil
    )
  }

  public static func project(
    source: CaptureSource,
    paths: RuntimePaths,
    heartbeat: Heartbeat?,
    freshnessTTL: TimeInterval,
    now: Date
  ) -> DaemonStatus {
    guard let heartbeat else { return stopped(source: source, paths: paths) }

    if now.timeIntervalSince(heartbeat.at) > freshnessTTL {
      return DaemonStatus(
        source: source,
        lifecycle: .stale,
        health: .stale,
        sidecars: DaemonSidecarPaths(paths: paths),
        lastHeartbeat: heartbeat.at,
        lastObservedPeak: heartbeat.peak,
        transcriptCounters: TranscriptCounters(final: heartbeat.transcriptFinalCount, volatile: heartbeat.transcriptVolatileCount),
        speakerLabelState: heartbeat.speakerLabelState,
        idleOutput: heartbeat.idleOutput,
        lastActionableError: ActionableError(
          code: "heartbeat_stale",
          message: "Heartbeat freshness expired for \(source.rawValue).",
          remediation: "Inspect or restart the source owner before trusting capture health."
        )
      )
    }

    let error: ActionableError?
    let health: DaemonHealth
    if case .failed(let reason) = heartbeat.speakerLabelState {
      health = .degraded
      error = ActionableError(
        code: "progressive_layer_failed",
        message: "Progressive speaker-label layer failed: \(reason).",
        remediation: "Keep base capture running and restart or disable the failed progressive layer."
      )
    } else if heartbeat.lifecycle == .failed {
      health = .failed
      error = ActionableError(
        code: "capture_failed",
        message: "Capture source reported failure.",
        remediation: "Inspect daemon logs and direct-mode rollback sidecars."
      )
    } else if heartbeat.idleOutput {
      health = .idleOutput
      error = nil
    } else if heartbeat.lifecycle == .degraded {
      health = .degraded
      error = nil
    } else {
      health = .healthy
      error = nil
    }

    return DaemonStatus(
      source: source,
      lifecycle: heartbeat.lifecycle,
      health: health,
      sidecars: DaemonSidecarPaths(paths: paths),
      lastHeartbeat: heartbeat.at,
      lastObservedPeak: heartbeat.peak,
      transcriptCounters: TranscriptCounters(final: heartbeat.transcriptFinalCount, volatile: heartbeat.transcriptVolatileCount),
      speakerLabelState: heartbeat.speakerLabelState,
      idleOutput: heartbeat.idleOutput,
      lastActionableError: error
    )
  }
}

private extension DaemonSidecarPaths {
  init(paths: RuntimePaths) {
    socket = paths.socketURL
    lock = paths.lockURL
    pid = paths.pidURL
    log = paths.logURL
  }
}
