import Foundation
import Observation
import ServiceManagement

/// Persisted operator preferences for ChronicleApp.
///
/// Properties are backed by `UserDefaults.standard` with keys prefixed `chronicle.`.
/// The `launchAtLogin` setter synchronously registers or unregisters via
/// `SMAppService.mainApp`; errors are logged and do not propagate.
@Observable
final class AppSettings {

    // MARK: - UserDefaults keys

    private enum Keys {
        static let diarizationEnabled = "chronicle.diarizationEnabled"
        static let launchAtLogin = "chronicle.launchAtLogin"
    }

    // MARK: - Backing storage

    /// Stored separately so `init` can assign without triggering side-effect observers.
    @ObservationIgnored private var _diarizationEnabled: Bool
    @ObservationIgnored private var _launchAtLogin: Bool

    // MARK: - Observable properties

    /// Whether diarization is enabled for new capture sessions.
    /// Persisted to `UserDefaults` on every write.
    var diarizationEnabled: Bool {
        get {
            access(keyPath: \.diarizationEnabled)
            return _diarizationEnabled
        }
        set {
            withMutation(keyPath: \.diarizationEnabled) {
                _diarizationEnabled = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Keys.diarizationEnabled)
        }
    }

    /// Whether the app should launch at login.
    /// Persisted to `UserDefaults` and synchronised with `SMAppService.mainApp` on every write.
    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return _launchAtLogin
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                _launchAtLogin = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Keys.launchAtLogin)
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[AppSettings] SMAppService \(newValue ? "register" : "unregister") failed: \(error)")
            }
        }
    }

    // MARK: - Init

    /// Reads persisted values from `UserDefaults` and syncs `launchAtLogin` with
    /// the actual `SMAppService.mainApp.status`.  Does **not** call register/unregister.
    init() {
        _diarizationEnabled = UserDefaults.standard.bool(forKey: Keys.diarizationEnabled)

        let storedLaunchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
        let serviceEnabled = SMAppService.mainApp.status == .enabled
        // Treat the service as ground truth: if it reports enabled the pref should mirror that.
        _launchAtLogin = storedLaunchAtLogin || serviceEnabled
    }
}
