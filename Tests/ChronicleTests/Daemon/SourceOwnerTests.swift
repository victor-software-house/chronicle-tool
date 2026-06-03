import Foundation
import Testing
@testable import ChronicleCore

@Suite("SourceOwner")
struct SourceOwnerTests {
  @Test("acquire writes active machine-readable owner snapshot")
  func acquireWritesActiveMachineReadableOwnerSnapshot() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: root)
    let owner = SourceOwner(paths: paths)

    let lease = try owner.acquire()
    defer { lease.release() }

    let snapshot = owner.inspect()
    #expect(snapshot.source == .sysaudio)
    #expect(snapshot.lifecycle == .capturing)
    #expect(snapshot.isActive)
    #expect(snapshot.pid == ProcessInfo.processInfo.processIdentifier)
    #expect(snapshot.epoch == lease.epoch)
    #expect(snapshot.pidURL == paths.pidURL)
    #expect(snapshot.lockURL == paths.lockURL)

    let encodedSnapshot = try JSONEncoder().encode(snapshot)
    let decodedSnapshot = try JSONDecoder().decode(SourceOwnerSnapshot.self, from: encodedSnapshot)
    #expect(decodedSnapshot == snapshot)
  }

  @Test("duplicate active owner is rejected before capture starts")
  func duplicateActiveOwnerIsRejectedBeforeCaptureStarts() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = RuntimePaths(source: .mic, rootDirectory: root)
    let firstOwner = SourceOwner(paths: paths)
    let secondOwner = SourceOwner(paths: paths)

    let firstLease = try firstOwner.acquire()
    defer { firstLease.release() }

    do {
      _ = try secondOwner.acquire()
      Issue.record("second owner unexpectedly acquired active mic lock")
    } catch let error as SourceOwnerError {
      guard case .alreadyOwned(let snapshot) = error else {
        Issue.record("unexpected SourceOwnerError: \(error)")
        return
      }
      #expect(snapshot.source == .mic)
      #expect(snapshot.lifecycle == .capturing)
      #expect(snapshot.isActive)
      #expect(snapshot.pid == ProcessInfo.processInfo.processIdentifier)
      #expect(snapshot.remediation.contains("chronicle stop mic"))
    }
  }

  @Test("stale ownership state is reported and recoverable")
  func staleOwnershipStateIsReportedAndRecoverable() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: root)
    try paths.prepareDirectories()
    let staleEpoch = DaemonEpoch(rawValue: "stale-epoch")
    let staleRecord = SourceOwnerRecord(
      source: .sysaudio,
      pid: 9_999_999,
      epoch: staleEpoch,
      acquiredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try JSONEncoder().encode(staleRecord)
    try data.write(to: paths.pidURL, options: .atomic)

    let owner = SourceOwner(paths: paths)
    let staleSnapshot = owner.inspect()
    #expect(staleSnapshot.source == .sysaudio)
    #expect(staleSnapshot.lifecycle == .stale)
    #expect(!staleSnapshot.isActive)
    #expect(staleSnapshot.pid == 9_999_999)
    #expect(staleSnapshot.epoch == staleEpoch)

    let lease = try owner.acquire()
    defer { lease.release() }
    #expect(lease.source == .sysaudio)
    #expect(lease.epoch != staleEpoch)

    let activeSnapshot = owner.inspect()
    #expect(activeSnapshot.lifecycle == .capturing)
    #expect(activeSnapshot.isActive)
    #expect(activeSnapshot.pid == ProcessInfo.processInfo.processIdentifier)
    #expect(activeSnapshot.epoch == lease.epoch)
  }

  @Test("sysaudio and mic ownership are independent")
  func sysaudioAndMicOwnershipAreIndependent() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sysaudioOwner = SourceOwner(paths: RuntimePaths(source: .sysaudio, rootDirectory: root))
    let micOwner = SourceOwner(paths: RuntimePaths(source: .mic, rootDirectory: root))

    let sysaudioLease = try sysaudioOwner.acquire()
    defer { sysaudioLease.release() }
    let micLease = try micOwner.acquire()
    defer { micLease.release() }

    #expect(sysaudioOwner.inspect().source == .sysaudio)
    #expect(micOwner.inspect().source == .mic)
    #expect(sysaudioOwner.inspect().lockURL != micOwner.inspect().lockURL)
    #expect(sysaudioLease.epoch != micLease.epoch)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("chronicle-source-owner-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
