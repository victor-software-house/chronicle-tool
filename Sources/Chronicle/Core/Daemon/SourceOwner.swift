import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// PID metadata persisted by a source owner after it acquires the ownership lock.
public struct SourceOwnerRecord: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let pid: Int32
  public let epoch: DaemonEpoch
  public let acquiredAt: Date

  public init(source: CaptureSource, pid: Int32, epoch: DaemonEpoch, acquiredAt: Date) {
    self.source = source
    self.pid = pid
    self.epoch = epoch
    self.acquiredAt = acquiredAt
  }
}

/// Machine-readable ownership state used by duplicate-owner responses and status projection.
public struct SourceOwnerSnapshot: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let lifecycle: DaemonLifecycle
  public let isActive: Bool
  public let pid: Int32?
  public let epoch: DaemonEpoch?
  public let acquiredAt: Date?
  public let lockURL: URL
  public let pidURL: URL
  public let remediation: String
}

public enum SourceOwnerError: Error, Equatable, CustomStringConvertible, Sendable {
  case alreadyOwned(SourceOwnerSnapshot)
  case invalidLockPath(String)
  case lockFailed(String)

  public var description: String {
    switch self {
    case .alreadyOwned(let snapshot):
      "source \(snapshot.source.rawValue) is already owned by pid \(snapshot.pid.map(String.init) ?? "unknown")"
    case .invalidLockPath(let path):
      "invalid source-owner lock path: \(path)"
    case .lockFailed(let message):
      "failed to acquire source-owner lock: \(message)"
    }
  }
}

/// Live ownership lease. Holding this object keeps the per-source lock active.
public final class SourceOwnerLease: @unchecked Sendable {
  public let source: CaptureSource
  public let epoch: DaemonEpoch
  public let pid: Int32

  private let fileDescriptor: Int32
  private let pidURL: URL
  private let onRelease: @Sendable () -> Void
  private let releaseLock = NSLock()
  private var released = false

  init(
    source: CaptureSource,
    epoch: DaemonEpoch,
    pid: Int32,
    fileDescriptor: Int32,
    pidURL: URL,
    onRelease: @escaping @Sendable () -> Void = {}
  ) {
    self.source = source
    self.epoch = epoch
    self.pid = pid
    self.fileDescriptor = fileDescriptor
    self.pidURL = pidURL
    self.onRelease = onRelease
  }

  deinit {
    release()
  }

  public func release() {
    releaseLock.lock()
    guard !released else {
      releaseLock.unlock()
      return
    }
    released = true
    releaseLock.unlock()

    try? FileManager.default.removeItem(at: pidURL)
#if canImport(Darwin) || canImport(Glibc)
    flock(fileDescriptor, LOCK_UN)
    close(fileDescriptor)
#endif
    onRelease()
  }
}

/// Per-source ownership gate backed by a non-blocking `flock` and PID metadata.
///
/// This type never opens microphone, CoreAudio, SpeechAnalyzer, or TCC resources.
public struct SourceOwner: Sendable {
  public let paths: RuntimePaths
  private let processID: Int32

  public init(paths: RuntimePaths, processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
    self.paths = paths
    self.processID = processID
  }

  public func acquire(epoch: DaemonEpoch = .fresh(), acquiredAt: Date = Date()) throws -> SourceOwnerLease {
    try paths.prepareDirectories()
    let fd = openLockFile()
    guard fd >= 0 else {
      throw SourceOwnerError.invalidLockPath(paths.lockURL.path)
    }

#if canImport(Darwin) || canImport(Glibc)
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let lockErrno = errno
      close(fd)
      if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
        throw SourceOwnerError.alreadyOwned(inspect())
      }
      throw SourceOwnerError.lockFailed(String(cString: strerror(lockErrno)))
    }
#endif

    let record = SourceOwnerRecord(source: paths.source, pid: processID, epoch: epoch, acquiredAt: acquiredAt)
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(record)
      try data.write(to: paths.pidURL, options: .atomic)
    } catch {
#if canImport(Darwin) || canImport(Glibc)
      flock(fd, LOCK_UN)
      close(fd)
#endif
      throw error
    }

    return SourceOwnerLease(
      source: paths.source,
      epoch: epoch,
      pid: processID,
      fileDescriptor: fd,
      pidURL: paths.pidURL
    )
  }

  public func inspect() -> SourceOwnerSnapshot {
    guard let record = readRecord() else {
      return snapshot(record: nil, lifecycle: .stopped, isActive: false)
    }
    let active = isProcessAlive(record.pid)
    return snapshot(record: record, lifecycle: active ? .capturing : .stale, isActive: active)
  }

  private func readRecord() -> SourceOwnerRecord? {
    guard let data = try? Data(contentsOf: paths.pidURL) else { return nil }
    return try? JSONDecoder().decode(SourceOwnerRecord.self, from: data)
  }

  private func snapshot(record: SourceOwnerRecord?, lifecycle: DaemonLifecycle, isActive: Bool) -> SourceOwnerSnapshot {
    SourceOwnerSnapshot(
      source: paths.source,
      lifecycle: lifecycle,
      isActive: isActive,
      pid: record?.pid,
      epoch: record?.epoch,
      acquiredAt: record?.acquiredAt,
      lockURL: paths.lockURL,
      pidURL: paths.pidURL,
      remediation: remediation(for: paths.source, lifecycle: lifecycle, pid: record?.pid)
    )
  }

  private func remediation(for source: CaptureSource, lifecycle: DaemonLifecycle, pid: Int32?) -> String {
    switch lifecycle {
    case .capturing, .starting, .reconfiguring, .degraded, .stopping, .escalating:
      return "Use chronicle stop \(source.rawValue) or attach to the existing owner before starting another capture."
    case .stale:
      return "Stale owner metadata can be replaced because pid \(pid.map(String.init) ?? "unknown") is no longer live."
    case .stopped:
      return "No active owner for \(source.rawValue)."
    case .failed:
      return "Inspect daemon logs before retrying \(source.rawValue)."
    }
  }

  private func openLockFile() -> Int32 {
#if canImport(Darwin) || canImport(Glibc)
    open(paths.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
#else
    -1
#endif
  }

  private func isProcessAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
#if canImport(Darwin) || canImport(Glibc)
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
#else
    return pid == processID
#endif
  }
}
