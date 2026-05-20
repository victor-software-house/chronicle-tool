import Foundation
import AVFoundation

/// Non-blocking TCC preflight checks for chronicle's active capture surfaces.
/// `microphone()` remains active for `MicAudioSource`; production `sysaudio`
/// uses `CoreAudioTapSource` and the System Audio Recording first-use prompt.
public enum TCCPreflight {

  /// Permission state for an audio capture surface.
  public enum State: Equatable, Sendable {
    /// User has explicitly granted the permission.
    case granted
    /// User has explicitly denied the permission.
    case denied
    /// Permission has not been determined yet (e.g. first run; only
    /// applicable to Microphone).
    case undetermined
  }

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

  // MARK: - System Audio Recording

  /// Declarative grant check for the CoreAudio process tap used by
  /// `chronicle sysaudio`. Backed by `TCCSystemAudio` (private TCC SPI via
  /// `dlopen`); returns `.undetermined` if the SPI is unavailable.
  public static func systemAudioRecording() -> State {
    TCCSystemAudio.preflight()
  }

  /// Triggers the macOS TCC prompt and blocks until the user decides.
  /// Returns the resulting `State` (granted / denied).
  public static func requestSystemAudioRecording() async -> State {
    await TCCSystemAudio.requestAndWait() ? .granted : .denied
  }

  public static let systemAudioRecordingRemediation: String = """
    System Audio Recording permission is required by `chronicle sysaudio`. \
    macOS CoreAudio process taps silently deliver zero-amplitude buffers when this grant is absent. \
    Grant it for the parent launcher (cmux.app, Terminal.app, iTerm.app, Ghostty, etc.) via: \
    System Settings → Privacy & Security → System Audio Recording. \
    Relaunch the parent app after granting so the grant propagates to child processes.
    """
}
