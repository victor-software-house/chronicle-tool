import AppKit
import ChronicleCore
import SwiftUI

@main
struct ChronicleApp: App {
  @State private var manager: CaptureManager
  @State private var settings: AppSettings

  init() {
    // Single-instance guard: if already running, activate and exit.
    let bundleID = Bundle.main.bundleIdentifier ?? "com.victor-software-house.chronicle"
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if running.count > 1 {
      // Another instance exists — activate it and terminate this one.
      if let existing = running.first(where: { $0 != .current }) {
        existing.activate()
      }
      // Defer termination so @main init completes before exit.
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    let s = AppSettings()
    _settings = State(initialValue: s)
    _manager = State(initialValue: CaptureManager(settings: s))

    // Register termination handler for clean shutdown.
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [manager = _manager] _ in
      let mgr = manager.wrappedValue
      Task { @MainActor in
        await mgr.shutdown()
      }
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarMenuContent(manager: manager, settings: settings)
    } label: {
      Image(systemName: menuBarIcon)
    }
    // .menuBarExtraStyle(.window)  // TODO: restore once popover positioning is verified
    .menuBarExtraStyle(.menu)
  }

  private var menuBarIcon: String {
    switch manager.state {
    case .idle: "waveform"
    case .recording: "record.circle.fill"
    case .stopping: "stop.circle"
    case .error: "exclamationmark.triangle.fill"
    }
  }
}
