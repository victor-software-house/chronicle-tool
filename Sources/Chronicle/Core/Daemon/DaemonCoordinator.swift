import Foundation

public struct CaptureEnsureResult: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let lifecycle: DaemonLifecycle
  public let status: LiveCaptureStatus
  public let existingOwner: SourceOwnerSnapshot?
}

public enum StopOutcome: String, Codable, Equatable, Sendable {
  case alreadyStopped = "already_stopped"
  case graceful
  case escalated
}

public struct CaptureStopResult: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let lifecycle: DaemonLifecycle
  public let outcome: StopOutcome
  public let status: LiveCaptureStatus
}

/// Coordinates daemon method behavior for one physical source.
public actor DaemonCoordinator {
  public let paths: RuntimePaths
  public let configuration: LiveCaptureConfiguration

  private let owner: SourceOwner
  private let session: LiveCaptureSession
  private var lease: SourceOwnerLease?
  private var ensureReplay: [ClientRequestID: CaptureEnsureResult] = [:]
  private var stopReplay: [ClientRequestID: CaptureStopResult] = [:]

  public init(paths: RuntimePaths, configuration: LiveCaptureConfiguration) {
    self.paths = paths
    self.configuration = configuration
    owner = SourceOwner(paths: paths)
    session = LiveCaptureSession(configuration: configuration)
  }

  public func ensure(clientRequestID: ClientRequestID) async throws -> CaptureEnsureResult {
    if let replay = ensureReplay[clientRequestID] { return replay }

    let current = await session.status()
    if current.lifecycle == .capturing || current.lifecycle == .reconfiguring || current.lifecycle == .degraded {
      let result = CaptureEnsureResult(
        source: configuration.source,
        lifecycle: current.lifecycle,
        status: current,
        existingOwner: owner.inspect()
      )
      ensureReplay[clientRequestID] = result
      return result
    }

    do {
      lease = try owner.acquire()
      let started = try await session.start()
      let result = CaptureEnsureResult(source: configuration.source, lifecycle: started.lifecycle, status: started, existingOwner: nil)
      ensureReplay[clientRequestID] = result
      return result
    } catch let error as SourceOwnerError {
      if case .alreadyOwned(let snapshot) = error {
        let status = await session.status()
        let result = CaptureEnsureResult(source: configuration.source, lifecycle: snapshot.lifecycle, status: status, existingOwner: snapshot)
        ensureReplay[clientRequestID] = result
        return result
      }
      throw error
    }
  }

  public func stop(clientRequestID: ClientRequestID) async -> CaptureStopResult {
    if let replay = stopReplay[clientRequestID] { return replay }

    let current = await session.status()
    if current.lifecycle == .stopped {
      let result = CaptureStopResult(source: configuration.source, lifecycle: .stopped, outcome: .alreadyStopped, status: current)
      stopReplay[clientRequestID] = result
      return result
    }

    let stopped = await session.stop(reason: .clientRequest)
    lease?.release()
    lease = nil
    let result = CaptureStopResult(source: configuration.source, lifecycle: stopped.lifecycle, outcome: .graceful, status: stopped)
    stopReplay[clientRequestID] = result
    return result
  }

  public func status() async -> DaemonStatus {
    let live = await session.status()
    guard live.lifecycle != .stopped else {
      return .stopped(source: configuration.source, paths: paths)
    }
    let heartbeat = Heartbeat(
      source: configuration.source,
      lifecycle: live.lifecycle,
      at: Date(),
      peak: live.lastObservedPeak,
      transcriptFinalCount: live.transcriptCounters.final,
      transcriptVolatileCount: live.transcriptCounters.volatile,
      speakerLabelState: live.speakerLabelState,
      idleOutput: live.lastObservedPeak == 0 && live.transcriptCounters.final == 0 && live.transcriptCounters.volatile == 0
    )
    return .project(source: configuration.source, paths: paths, heartbeat: heartbeat, freshnessTTL: 10, now: Date())
  }
}
