import Foundation

public enum DaemonError: Error, CustomStringConvertible, Sendable {
  case alreadyRunning

  public var description: String {
    switch self {
    case .alreadyRunning: "Daemon is already running for this source."
    }
  }
}

/// Top-level daemon process composition for a single physical source.
///
/// Wires `SourceOwner` (duplicate-owner gate), `DaemonCoordinator`,
/// `DaemonEventLog`, `EventHub`, and the local `RPCServer`. Construction is
/// pure; `start` is the only call that touches the filesystem ownership,
/// socket, or audio resources.
public actor Daemon {
  public let paths: RuntimePaths
  public let configuration: LiveCaptureConfiguration
  public let coordinator: DaemonCoordinator
  public let eventHub: EventHub

  private let owner: SourceOwner
  private var ownerLease: SourceOwnerLease?
  private var eventLog: DaemonEventLog?
  private var server: RPCServer?
  private var _isRunning = false

  public init(paths: RuntimePaths, configuration: LiveCaptureConfiguration) {
    self.paths = paths
    self.configuration = configuration
    coordinator = DaemonCoordinator(paths: paths, configuration: configuration)
    eventHub = EventHub()
    owner = SourceOwner(paths: paths)
  }

  public var isRunning: Bool { _isRunning }

  public func start(heartbeatInterval: TimeInterval = 0) async throws {
    guard !_isRunning else { throw DaemonError.alreadyRunning }

    let snapshot = owner.inspect()
    if snapshot.isActive {
      throw SourceOwnerError.alreadyOwned(snapshot)
    }

    try paths.prepareDirectories()

    let priorEvents = (try? DaemonEventLog.read(url: paths.logURL)) ?? []
    let priorEpoch = priorEvents.last?.epoch
    let crashed = !priorEvents.isEmpty && priorEvents.last?.type != "daemon.stopped"

    let lease = try owner.acquire()
    ownerLease = lease
    await coordinator.attachOwnerLease(lease)

    let resumedSequence = (priorEvents.last?.sequence ?? 0) + 1
    let log = DaemonEventLog(url: paths.logURL, source: configuration.source, epoch: lease.epoch, nextSequence: resumedSequence)
    if crashed, let priorEpoch {
      _ = try log.appendRecovery(previousEpoch: priorEpoch, reason: "unclean termination detected on restart")
    }
    _ = try log.append(stream: .manifest, type: "daemon.started", payload: [
      "pid": .number(Double(lease.pid)),
      "socket": .string(paths.socketURL.path),
    ])
    eventLog = log
    await coordinator.attachEventStreams(eventHub: eventHub, eventLog: log)

    let idempotencyStore = IdempotencyStore(epoch: lease.epoch)
    idempotencyStore.load(from: paths.idempotencyURL)

    let rpc = RPCServer(paths: paths, coordinator: coordinator, eventHub: eventHub, idempotencyStore: idempotencyStore)
    try rpc.start()
    server = rpc

    if heartbeatInterval > 0 {
      await coordinator.startHeartbeats(interval: heartbeatInterval)
    }

    _isRunning = true
  }

  /// Test helper: simulate hard kill by dropping the lease and socket without writing the daemon.stopped trailer.
  public func simulateHardKill() async {
    guard _isRunning else { return }
    await coordinator.stopHeartbeats()
    server?.stop()
    server = nil
    ownerLease?.release()
    ownerLease = nil
    eventLog = nil
    _isRunning = false
  }

  public func stop() async {
    guard _isRunning else { return }
    await coordinator.stopHeartbeats()
    server?.stop()
    server = nil

    if let log = eventLog {
      _ = try? log.append(stream: .manifest, type: "daemon.stopped", payload: [
        "pid": .number(Double(ownerLease?.pid ?? 0)),
      ])
    }

    ownerLease?.release()
    ownerLease = nil
    eventLog = nil
    _isRunning = false
  }
}
