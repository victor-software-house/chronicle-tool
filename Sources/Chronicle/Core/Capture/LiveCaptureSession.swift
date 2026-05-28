import Foundation

public protocol LiveCaptureSessionProtocol: Sendable {
  func start() async throws -> LiveCaptureStatus
  func stop(reason: StopReason) async -> LiveCaptureStatus
  func reconfigure(_ change: LiveCaptureChange) async -> ReconfigureOutcome
  func status() async -> LiveCaptureStatus
}

public enum StopReason: String, Codable, Equatable, Sendable {
  case clientRequest = "client_request"
  case signal
  case failure
}

public enum ReconfigureOutcome: Equatable, Sendable {
  case appliedLive
  case futureSegment
  case rejected(reason: String, alternative: String)
}

public struct LiveCaptureSidecars: Codable, Equatable, Sendable {
  public let tracePath: String?
  public let finalsPath: String?
  public let livePath: String?
  public let audioPath: String?
}

public struct LiveCaptureStatus: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let lifecycle: DaemonLifecycle
  public let sidecars: LiveCaptureSidecars
  public let roughTranscriptActive: Bool
  public let lastObservedPeak: Int
  public let transcriptCounters: TranscriptCounters
  public let speakerLabelState: SpeakerLabelState
}

/// Reusable daemon/direct capture session state boundary.
///
/// Models lifecycle, status, and safe reconfiguration without opening live audio
/// during construction. Direct command integration is owned by the next task so
/// the installed live capture processes can remain undisturbed.
public actor LiveCaptureSession: LiveCaptureSessionProtocol {
  public let configuration: LiveCaptureConfiguration
  private var currentStatus: LiveCaptureStatus

  public init(configuration: LiveCaptureConfiguration) {
    self.configuration = configuration
    currentStatus = LiveCaptureStatus(
      source: configuration.source,
      lifecycle: .stopped,
      sidecars: LiveCaptureSidecars(configuration: configuration),
      roughTranscriptActive: false,
      lastObservedPeak: 0,
      transcriptCounters: TranscriptCounters(final: 0, volatile: 0),
      speakerLabelState: configuration.diarizationEnabled ? .warming : .unavailable
    )
  }

  public func start() async throws -> LiveCaptureStatus {
    currentStatus = LiveCaptureStatus(
      source: configuration.source,
      lifecycle: .capturing,
      sidecars: LiveCaptureSidecars(configuration: configuration),
      roughTranscriptActive: true,
      lastObservedPeak: 0,
      transcriptCounters: TranscriptCounters(final: 0, volatile: 0),
      speakerLabelState: configuration.diarizationEnabled ? .warming : .unavailable
    )
    return currentStatus
  }

  public func stop(reason: StopReason) async -> LiveCaptureStatus {
    currentStatus = LiveCaptureStatus(
      source: configuration.source,
      lifecycle: .stopped,
      sidecars: currentStatus.sidecars,
      roughTranscriptActive: false,
      lastObservedPeak: currentStatus.lastObservedPeak,
      transcriptCounters: currentStatus.transcriptCounters,
      speakerLabelState: currentStatus.speakerLabelState
    )
    return currentStatus
  }

  public func reconfigure(_ change: LiveCaptureChange) async -> ReconfigureOutcome {
    switch configuration.policy(for: change, whileActive: currentStatus.lifecycle != .stopped) {
    case .applyBeforeStart:
      return .futureSegment
    case .applyLive:
      if case .setDiarization(let enabled) = change {
        currentStatus = LiveCaptureStatus(
          source: currentStatus.source,
          lifecycle: currentStatus.lifecycle,
          sidecars: currentStatus.sidecars,
          roughTranscriptActive: currentStatus.roughTranscriptActive,
          lastObservedPeak: currentStatus.lastObservedPeak,
          transcriptCounters: currentStatus.transcriptCounters,
          speakerLabelState: enabled ? .warming : .unavailable
        )
      }
      return .appliedLive
    case .futureSegment:
      return .futureSegment
    case .reject(let reason, let alternative):
      return .rejected(reason: reason, alternative: alternative)
    }
  }

  public func status() async -> LiveCaptureStatus {
    currentStatus
  }
}

private extension LiveCaptureSidecars {
  init(configuration: LiveCaptureConfiguration) {
    tracePath = configuration.tracePath
    finalsPath = configuration.finalsPath
    livePath = configuration.livePath
    audioPath = configuration.audioPath
  }
}
