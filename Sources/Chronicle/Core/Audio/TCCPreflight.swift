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
}
