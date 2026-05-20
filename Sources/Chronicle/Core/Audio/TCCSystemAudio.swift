import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Declarative TCC grant check for chronicle's CoreAudio process tap.
///
/// Apple ships no public synchronous API to query the System Audio Recording
/// (a.k.a. Audio Capture, `kTCCServiceAudioCapture`) grant. Industry standard
/// — established by Marin Todorov's `AudioCap` sample — is to `dlopen` the
/// private `TCC.framework` and call `TCCAccessPreflight` / `TCCAccessRequest`.
/// This module wraps that pattern.
///
/// Build flag `DISABLE_TCC_SPI`: when set (`-DDISABLE_TCC_SPI`), all checks
/// short-circuit to `.undetermined` and chronicle proceeds without enforcing
/// the grant. Use for App Store / strict compliance builds where private SPI
/// is forbidden.
public enum TCCSystemAudio {

  /// TCC service identifiers consulted in order. macOS 14.4 introduced
  /// CoreAudio process taps under `kTCCServiceAudioCapture`. macOS 15
  /// (Sequoia) split it into `kTCCServiceSystemAudioRecording` for tap-style
  /// capture while keeping `kTCCServiceAudioCapture` as a legacy alias on
  /// some configurations. We check both: if either reports granted, we let
  /// the tap run. If either reports denied (and the other is undetermined)
  /// we surface denial. Undetermined on both → trigger prompt.
  public static let candidateServices = [
    "kTCCServiceAudioCapture",
    "kTCCServiceSystemAudioRecording",
  ]

  // MARK: - Public API

  /// Synchronous grant check. Safe to call any number of times.
  public static func preflight() -> TCCPreflight.State {
    #if DISABLE_TCC_SPI
    return .undetermined
    #else
    guard let preflightFn = Self.preflightSPI else { return .undetermined }
    let debug = ProcessInfo.processInfo.environment["CHRONICLE_TCC_DEBUG"] == "1"
    var sawDenied = false
    for service in candidateServices {
      let raw = preflightFn(service as CFString, nil)
      if debug {
        FileHandle.standardError.write(Data(
          "[tcc] preflight(\(service)) → \(raw)  (0=granted 1=denied other=undetermined)\n".utf8
        ))
      }
      switch raw {
      case 0:  return .granted
      case 1:  sawDenied = true
      default: break
      }
    }
    return sawDenied ? .denied : .undetermined
    #endif
  }

  /// Trigger the macOS first-use TCC prompt and block until the user decides.
  /// Returns `true` on grant, `false` on denial. Returns `false` if the SPI
  /// is unavailable. Requests each candidate service in order until one is
  /// granted.
  public static func requestAndWait() async -> Bool {
    #if DISABLE_TCC_SPI
    return false
    #else
    guard let requestFn = Self.requestSPI else { return false }
    for service in candidateServices {
      let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        requestFn(service as CFString, nil) { result in
          continuation.resume(returning: result)
        }
      }
      if granted { return true }
    }
    return false
    #endif
  }

  /// Deep-link the user to System Settings → Privacy & Security → System
  /// Audio Recording. Fires the `open` command asynchronously so callers
  /// can use it as a courtesy after a denial.
  public static func openSystemSettingsPane() {
    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudio"
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = [url]
    try? task.run()
  }

  // MARK: - Private TCC SPI bridge

  #if !DISABLE_TCC_SPI
  private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
  private typealias RequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

  private nonisolated(unsafe) static let apiHandle: UnsafeMutableRawPointer? = {
    let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
    return dlopen(path, RTLD_NOW)
  }()

  private nonisolated(unsafe) static let preflightSPI: PreflightFuncType? = {
    guard let apiHandle, let sym = dlsym(apiHandle, "TCCAccessPreflight") else { return nil }
    return unsafeBitCast(sym, to: PreflightFuncType.self)
  }()

  private nonisolated(unsafe) static let requestSPI: RequestFuncType? = {
    guard let apiHandle, let sym = dlsym(apiHandle, "TCCAccessRequest") else { return nil }
    return unsafeBitCast(sym, to: RequestFuncType.self)
  }()
  #endif
}
