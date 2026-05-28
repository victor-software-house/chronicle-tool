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

public struct ReconfigureResult: Equatable, Sendable {
  public let source: CaptureSource
  public let outcome: ReconfigureOutcome
  public let status: LiveCaptureStatus
  public let error: RPCError?
}

/// Coordinates daemon method behavior for one physical source.
public actor DaemonCoordinator {
  public let paths: RuntimePaths
  public let configuration: LiveCaptureConfiguration

  private let owner: SourceOwner
  private let session: LiveCaptureSession
  private var lease: SourceOwnerLease?
  private var externallyManagedLease = false
  private var ensureReplay: [ClientRequestID: CaptureEnsureResult] = [:]
  private var stopReplay: [ClientRequestID: CaptureStopResult] = [:]
  private var reconfigureReplay: [ClientRequestID: ReconfigureResult] = [:]
  private var markerReplay: [ClientRequestID: MarkerResult] = [:]
  private var clipReplay: [ClientRequestID: ClipResult] = [:]
  private var events: [DaemonEvent] = []
  private var nextEventSequence = 1
  private var coordinationLeases: LeaseStore
  private var eventHub: EventHub?
  private var eventLog: DaemonEventLog?
  private var heartbeatTask: Task<Void, Never>?

  public init(paths: RuntimePaths, configuration: LiveCaptureConfiguration) {
    self.paths = paths
    self.configuration = configuration
    owner = SourceOwner(paths: paths)
    session = LiveCaptureSession(configuration: configuration)
    coordinationLeases = LeaseStore(epoch: DaemonEpoch(rawValue: "unowned"), source: configuration.source)
  }

  /// Attach a pre-acquired owner lease (e.g. from `Daemon.start`) so subsequent
  /// `ensure` calls reuse it instead of trying to flock the source again. The
  /// coordinator will not release an externally attached lease on `stop`.
  public func attachOwnerLease(_ lease: SourceOwnerLease) {
    self.lease = lease
    self.externallyManagedLease = true
    self.coordinationLeases = LeaseStore(epoch: lease.epoch, source: configuration.source)
  }

  /// Attach a shared EventHub and DaemonEventLog so coordinator events are
  /// fanned out to in-process subscribers and persisted to durable JSONL with
  /// monotonically increasing sequences owned by the log.
  public func attachEventStreams(eventHub: EventHub?, eventLog: DaemonEventLog?) {
    self.eventHub = eventHub
    self.eventLog = eventLog
  }

  /// Start (or restart) a background heartbeat loop. Each tick reads
  /// `session.status()`, builds a heartbeat payload, and records it through
  /// the shared event sink (durable JSONL + EventHub). Ticks where the session
  /// lifecycle is `.stopped` are skipped so an idle daemon does not emit
  /// noisy stopped-heartbeat records.
  public func startHeartbeats(interval: TimeInterval = 1.0) {
    heartbeatTask?.cancel()
    let safeInterval = max(0.01, interval)
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(safeInterval * 1_000_000_000))
        if Task.isCancelled { break }
        await self?.emitHeartbeat()
      }
    }
  }

  public func stopHeartbeats() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  private func emitHeartbeat() async {
    sweepLeases()
    let live = await session.status()
    guard live.lifecycle != .stopped else { return }
    let idleOutput = live.lastObservedPeak == 0
      && live.transcriptCounters.final == 0
      && live.transcriptCounters.volatile == 0
    _ = record(stream: .heartbeat, type: "heartbeat", payload: [
      "lifecycle": .string(live.lifecycle.rawValue),
      "peak": .number(Double(live.lastObservedPeak)),
      "transcript_final": .number(Double(live.transcriptCounters.final)),
      "transcript_volatile": .number(Double(live.transcriptCounters.volatile)),
      "idle_output": .bool(idleOutput),
    ])
  }

  public var scratchDirectory: URL {
    paths.sourceDirectory.appendingPathComponent("scratch", isDirectory: true)
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
      if lease == nil {
        lease = try owner.acquire()
      }
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
    if !externallyManagedLease {
      lease?.release()
      lease = nil
    }
    let result = CaptureStopResult(source: configuration.source, lifecycle: stopped.lifecycle, outcome: .graceful, status: stopped)
    stopReplay[clientRequestID] = result
    return result
  }

  public func reconfigure(_ change: LiveCaptureChange, clientRequestID: ClientRequestID) async -> ReconfigureResult {
    if let replay = reconfigureReplay[clientRequestID] { return replay }

    appendControlEvent(type: "capture.reconfigure.started", payload: ["client_req_id": .string(clientRequestID.rawValue)])
    let outcome = await session.reconfigure(change)
    let status = await session.status()
    let result: ReconfigureResult
    switch outcome {
    case .appliedLive, .futureSegment:
      appendControlEvent(type: "capture.reconfigure.succeeded", payload: ["client_req_id": .string(clientRequestID.rawValue)])
      result = ReconfigureResult(source: configuration.source, outcome: outcome, status: status, error: nil)
    case .rejected(let reason, let alternative):
      appendControlEvent(type: "capture.reconfigure.failed", payload: ["client_req_id": .string(clientRequestID.rawValue), "reason": .string(reason)])
      result = ReconfigureResult(
        source: configuration.source,
        outcome: outcome,
        status: status,
        error: RPCError(
          code: .invalidConfig,
          message: reason,
          retriable: false,
          hint: alternative,
          details: ["source": .string(configuration.source.rawValue)]
        )
      )
    }
    reconfigureReplay[clientRequestID] = result
    return result
  }

  public func controlEvents() -> [DaemonEvent] {
    events
  }

  public func createMarker(label: String, clientRequestID: ClientRequestID) async -> MarkerResult {
    if let replay = markerReplay[clientRequestID] { return replay }
    let live = await session.status()
    guard live.lifecycle == .capturing || live.lifecycle == .reconfiguring || live.lifecycle == .degraded else {
      let result = MarkerResult(
        source: configuration.source,
        event: nil,
        error: RPCError(
          code: .noActiveSession,
          message: "No active capture session for marker.",
          retriable: false,
          hint: "Call capture.ensure before mark.create.",
          details: ["source": .string(configuration.source.rawValue)]
        )
      )
      markerReplay[clientRequestID] = result
      return result
    }
    let event = record(stream: .control, type: "marker.created", payload: [
      "label": .string(label),
      "client_req_id": .string(clientRequestID.rawValue),
    ])
    let result = MarkerResult(source: configuration.source, event: event, error: nil)
    markerReplay[clientRequestID] = result
    return result
  }

  public func createClip(request: ClipRequest, clientRequestID: ClientRequestID) async -> ClipResult {
    if let replay = clipReplay[clientRequestID] { return replay }
    sweepLeases()
    let coordinationLease = try? coordinationLeases.acquire(purpose: "clip.create", holder: clientRequestID.rawValue, ttl: 30)
    if let lease = coordinationLease {
      _ = record(stream: .control, type: "lease.acquired", payload: leasePayload(lease))
    }
    let result = await ClipCoordinator.export(
      source: configuration.source,
      scratchDirectory: scratchDirectory,
      request: request
    )
    if let leaseID = coordinationLease?.id, let released = try? coordinationLeases.release(id: leaseID) {
      _ = record(stream: .control, type: "lease.released", payload: leasePayload(released))
    }
    clipReplay[clientRequestID] = result
    return result
  }

  public func activeCoordinationLeases(now: Date = Date()) -> [Lease] {
    coordinationLeases.activeLeases(now: now)
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
      idleOutput: live.lastObservedPeak == 0
        && live.transcriptCounters.final == 0
        && live.transcriptCounters.volatile == 0
    )
    return .project(source: configuration.source, paths: paths, heartbeat: heartbeat, freshnessTTL: 10, now: Date())
  }

  /// Acquire a TTL coordination lease for multi-step client operations.
  /// Lease lifetime is bounded by `ttl`; expired leases are swept on every
  /// acquire/renew call and on every heartbeat tick (Req 7.5).
  @discardableResult
  public func acquireCoordinationLease(purpose: String, holder: String, ttl: TimeInterval) throws -> Lease {
    sweepLeases()
    let lease = try coordinationLeases.acquire(purpose: purpose, holder: holder, ttl: ttl)
    _ = record(stream: .control, type: "lease.acquired", payload: leasePayload(lease))
    return lease
  }

  @discardableResult
  public func renewCoordinationLease(id: LeaseID, ttl: TimeInterval) throws -> Lease {
    sweepLeases()
    let lease = try coordinationLeases.renew(id: id, ttl: ttl)
    _ = record(stream: .control, type: "lease.renewed", payload: leasePayload(lease))
    return lease
  }

  @discardableResult
  public func releaseCoordinationLease(id: LeaseID) throws -> Lease {
    let lease = try coordinationLeases.release(id: id)
    _ = record(stream: .control, type: "lease.released", payload: leasePayload(lease))
    return lease
  }

  private func sweepLeases() {
    let expired = coordinationLeases.expire()
    for lease in expired {
      _ = record(stream: .control, type: "lease.expired", payload: leasePayload(lease))
    }
  }

  private func leasePayload(_ lease: Lease) -> [String: JSONValue] {
    [
      "lease_id": .string(lease.id.rawValue),
      "purpose": .string(lease.purpose),
      "holder": .string(lease.holder),
      "expires_at": .string(ISO8601DateFormatter().string(from: lease.expiresAt)),
    ]
  }

  private func appendControlEvent(type: String, payload: [String: JSONValue]) {
    _ = record(stream: .control, type: type, payload: payload)
  }

  /// Single sink for coordinator-owned events. Uses the attached DaemonEventLog
  /// for durable sequence ownership and JSONL persistence when present; falls
  /// back to an in-memory sequence so unit tests of the coordinator alone keep
  /// working. Always publishes to the attached EventHub (if any) and to the
  /// in-memory `events` audit array.
  @discardableResult
  private func record(stream: DaemonEventStream, type: String, payload: [String: JSONValue]) -> DaemonEvent {
    if let eventLog {
      do {
        let event = try eventLog.append(stream: stream, type: type, payload: payload)
        events.append(event)
        nextEventSequence = max(nextEventSequence, event.sequence + 1)
        eventHub?.publish(event)
        return event
      } catch {
        // fall through to in-memory event
      }
    }
    let event = DaemonEvent(
      sequence: nextEventSequence,
      epoch: lease?.epoch ?? DaemonEpoch(rawValue: "unowned"),
      source: configuration.source,
      stream: stream,
      monotonicSeconds: ProcessInfo.processInfo.systemUptime,
      wallClock: Date(),
      type: type,
      payload: payload
    )
    events.append(event)
    nextEventSequence += 1
    eventHub?.publish(event)
    return event
  }
}
