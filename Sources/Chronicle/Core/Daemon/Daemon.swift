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

  public func start() async throws {
    guard !_isRunning else { throw DaemonError.alreadyRunning }

    let snapshot = owner.inspect()
    if snapshot.isActive {
      throw SourceOwnerError.alreadyOwned(snapshot)
    }

    try paths.prepareDirectories()
    let lease = try owner.acquire()
    ownerLease = lease

    var log = DaemonEventLog(url: paths.logURL, source: configuration.source, epoch: lease.epoch)
    _ = try log.append(stream: .manifest, type: "daemon.started", payload: [
      "pid": .number(Double(lease.pid)),
      "socket": .string(paths.socketURL.path),
    ])
    eventLog = log

    let rpc = RPCServer(paths: paths)
    try rpc.start()
    server = rpc

    _isRunning = true
  }

  public func stop() async {
    guard _isRunning else { return }
    server?.stop()
    server = nil

    if var log = eventLog {
      _ = try? log.append(stream: .manifest, type: "daemon.stopped", payload: [
        "pid": .number(Double(ownerLease?.pid ?? 0)),
      ])
      eventLog = log
    }

    ownerLease?.release()
    ownerLease = nil
    _isRunning = false
  }
}
