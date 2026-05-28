import Foundation

/// Physical capture sources owned by the daemon control plane.
public enum CaptureSource: String, CaseIterable, Codable, Hashable, Sendable {
  /// System output captured through the existing CoreAudio process tap path.
  case sysaudio
  /// Microphone input captured through the existing AVFoundation path.
  case mic
}

/// Source-owner lifecycle values exposed through status, ownership, and RPC.
public enum DaemonLifecycle: String, CaseIterable, Codable, Hashable, Sendable {
  /// No capture owner is running for this source.
  case stopped
  /// Owner process is setting up; live audio is not yet flowing.
  case starting
  /// Active capture is in progress.
  case capturing
  /// A hot reconfiguration is in progress; rough transcript capture remains active.
  case reconfiguring
  /// Capture is running but a non-fatal layer or health issue is present.
  case degraded
  /// Graceful shutdown is in progress.
  case stopping
  /// Graceful shutdown exceeded its bound and escalation is in progress.
  case escalating
  /// Ownership state exists but the owning process is no longer live.
  case stale
  /// Owner failed to start or encountered an unrecoverable error.
  case failed
}

/// Daemon epoch identifier used to separate ownership/event generations.
public struct DaemonEpoch: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func fresh() -> DaemonEpoch {
    DaemonEpoch(rawValue: UUID().uuidString.lowercased())
  }
}

/// Client-supplied idempotency key for mutating control-plane requests.
public struct ClientRequestID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}
