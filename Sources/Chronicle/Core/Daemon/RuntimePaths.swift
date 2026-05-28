import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Per-user, per-source runtime paths for local daemon control.
///
/// Resolution is pure filesystem bookkeeping: constructing this value does not
/// open audio devices, check TCC, bind sockets, or acquire ownership locks.
public struct RuntimePaths: Equatable, Sendable {
  public let source: CaptureSource
  public let rootDirectory: URL
  public let sourceDirectory: URL

  /// Unix domain socket for local JSON-RPC control.
  public let socketURL: URL
  /// `flock` file used by the source ownership gate.
  public let lockURL: URL
  /// PID metadata written by the owning daemon process.
  public let pidURL: URL
  /// Append-only daemon control/event log.
  public let logURL: URL
  public let idempotencyURL: URL

  public init(
    source: CaptureSource,
    rootDirectory: URL = RuntimePaths.defaultRootDirectory()
  ) {
    self.source = source
    self.rootDirectory = rootDirectory
    sourceDirectory = rootDirectory.appendingPathComponent(source.rawValue, isDirectory: true)
    socketURL = sourceDirectory.appendingPathComponent("control.sock")
    lockURL = sourceDirectory.appendingPathComponent("owner.lock")
    pidURL = sourceDirectory.appendingPathComponent("owner.pid")
    logURL = sourceDirectory.appendingPathComponent("daemon.jsonl")
    idempotencyURL = sourceDirectory.appendingPathComponent("idempotency.json")
  }

  /// Resolve Chronicle's per-user runtime root.
  ///
  /// Linux-style `XDG_RUNTIME_DIR` is honored when present and absolute. macOS
  /// normally lacks it, so the fallback is a user-scoped temp root named with
  /// the numeric UID. The returned URL always points at a local file path.
  public static func defaultRootDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let xdg = environment["XDG_RUNTIME_DIR"], xdg.hasPrefix("/") {
      return URL(fileURLWithPath: xdg, isDirectory: true)
        .appendingPathComponent("chronicle", isDirectory: true)
    }

    return FileManager.default.temporaryDirectory
      .appendingPathComponent("chronicle-\(currentUserID())", isDirectory: true)
  }

  /// Create the runtime directories with private per-user permissions.
  ///
  /// This prepares filesystem containers only; it does not create sockets, PID
  /// files, logs, locks, or live capture resources.
  public func prepareDirectories(fileManager: FileManager = .default) throws {
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true,
      attributes: attributes
    )
    try fileManager.setAttributes(attributes, ofItemAtPath: rootDirectory.path)
    try fileManager.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: true,
      attributes: attributes
    )
    try fileManager.setAttributes(attributes, ofItemAtPath: sourceDirectory.path)
  }

  private static func currentUserID() -> UInt32 {
#if canImport(Darwin) || canImport(Glibc)
    getuid()
#else
    0
#endif
  }
}
