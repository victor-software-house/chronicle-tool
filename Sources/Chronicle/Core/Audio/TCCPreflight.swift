import Foundation
import AVFoundation
import CoreGraphics

/// Non-blocking TCC preflight checks for chronicle's capture surfaces.
/// `microphone()` remains active for `MicAudioSource`. `screenRecording()`
/// is retained for deprecated `SysAudioSource` / ScreenCaptureKit reference
/// tests only; production `sysaudio` uses `CoreAudioTapSource` and the System
/// Audio Recording first-use prompt instead.
public enum TCCPreflight {

  /// Permission state for an audio capture surface.
  public enum State: Equatable, Sendable {
    /// User has explicitly granted the permission.
    case granted
    /// User has explicitly denied the permission, OR no entry exists in
    /// the TCC database (`CGPreflightScreenCaptureAccess` returns false
    /// in both cases — they're observably identical).
    case denied
    /// Permission has not been determined yet (e.g. first run; only
    /// applicable to Microphone).
    case undetermined
  }

  // MARK: - Screen Recording

  /// Check Screen Recording TCC grant for this process. Legacy helper for
  /// deprecated `SysAudioSource` before calling `SCStream.startCapture()`.
  ///
  /// `CGPreflightScreenCaptureAccess` is a non-blocking lookup against
  /// the TCC database. Documented in Apple's Tahoe ScreenCaptureKit
  /// sample code as the canonical preflight API.
  ///
  /// Note: macOS attributes TCC requests to the **parent app** in the
  /// responsibility chain (cmux.app, Terminal.app, etc.) for unsigned
  /// dev binaries. The grant must be on that parent.
  public static func screenRecording() -> State {
    CGPreflightScreenCaptureAccess() ? .granted : .denied
  }

  /// Trigger the macOS permission prompt for Screen & System Audio Recording.
  /// Legacy helper for the deprecated SCStream path. Production system-audio
  /// capture prompts through CoreAudio process tap creation.
  @discardableResult
  public static func requestScreenRecording() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  /// Human-readable remediation message for `screenRecording() == .denied`.
  public static let screenRecordingRemediation: String = """
    Screen & System Audio Recording permission is required by `chronicle sysaudio` \
    (ScreenCaptureKit audio capture piggy-backs on this entitlement). \
    Grant it for the parent terminal/launcher app (cmux.app, Terminal.app, iTerm.app, etc.) via: \
    System Settings → Privacy & Security → Screen & System Audio Recording. \
    After granting, macOS will prompt you to relaunch the parent app.
    """

  // MARK: - Microphone

  /// Check Microphone TCC grant for this process. Used by
  /// `MicAudioSource` before starting `AVAudioEngine`.
  public static func microphone() -> State {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:      return .granted
    case .denied:       return .denied
    case .undetermined: return .undetermined
    @unknown default:   return .undetermined
    }
  }

  public static let microphoneRemediation: String = """
    Microphone permission is required by `chronicle mic`. \
    Grant it for the parent terminal/launcher app (cmux.app, Terminal.app, iTerm.app, etc.) via: \
    System Settings → Privacy & Security → Microphone. \
    After granting, macOS will prompt you to relaunch the parent app.
    """
}
