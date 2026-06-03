import AppKit
import SwiftUI

/// Menu-style dropdown content — uses only Button, Toggle, Divider, Text.
/// Fallback from window-style MenuBarView when popover positioning fails.
struct MenuBarMenuContent: View {
  let manager: CaptureManager
  @Bindable var settings: AppSettings

  var body: some View {
    // Status
    if case .recording(let sources) = manager.state {
      Text("Recording: \(sources.map(\.rawValue).sorted().joined(separator: ", "))")
      if let d = manager.sessionDuration {
        Text(formatDuration(d))
      }
      if settings.diarizationEnabled && manager.speakerCount > 0 {
        Text("\(manager.speakerCount) speaker\(manager.speakerCount == 1 ? "" : "s")")
      }
      Divider()
    } else if case .stopping = manager.state {
      Text("Stopping\u{2026}")
      Divider()
    }

    // Last transcript line
    if let last = manager.transcriptLines.last {
      let prefix = last.speakerId.map { "[\($0)] " } ?? ""
      Text("\(prefix)\(last.text)")
        .lineLimit(2)
    } else if case .idle = manager.state {
      Text("No active session")
    }

    Divider()

    // Capture controls
    if case .recording = manager.state {
      Button("Stop") { Task { await manager.stopCapture() } }
    } else if case .stopping = manager.state {
      Button("Stopping\u{2026}") { }.disabled(true)
    } else {
      Button("Start Mic") { Task { await manager.startCapture(sources: [.mic]) } }
      Button("Start System Audio") { Task { await manager.startCapture(sources: [.sysaudio]) } }
      Button("Start Both") { Task { await manager.startCapture(sources: [.mic, .sysaudio]) } }
    }

    Divider()

    Toggle("Diarize", isOn: $settings.diarizationEnabled)

    Divider()

    // Error
    if case .error(let msg) = manager.state {
      Text("Error: \(msg)")
      Divider()
    }

    // Session folder
    if let url = manager.sessionOutputURL {
      Button("Open Session Folder") {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/code")
        task.arguments = [url.path]
        try? task.run()
      }
    }

    Toggle("Launch at Login", isOn: $settings.launchAtLogin)

    Divider()

    Button("Quit Chronicle") {
      Task {
        await manager.shutdown()
        NSApp.terminate(nil)
      }
    }
    .keyboardShortcut("q")
  }

  private func formatDuration(_ d: Duration) -> String {
    let total = Int(d.components.seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
  }
}
