import AppKit
import SwiftUI

/// Window-style dropdown content for the MenuBarExtra.
struct MenuBarView: View {
  let manager: CaptureManager
  @Bindable var settings: AppSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header
      HStack {
        Text("Chronicle")
          .font(.headline)
        Spacer()
        statusBadge
      }

      Divider()

      // Capture controls
      captureControls

      Divider()

      // Diarization toggle
      Toggle("Diarize", isOn: $settings.diarizationEnabled)
        .font(.callout)

      Divider()

      // Session info
      SessionInfoView(
        duration: manager.sessionDuration,
        activeSources: manager.activeSources,
        speakerCount: manager.speakerCount,
        diarizationEnabled: settings.diarizationEnabled,
        audioHealthWarning: manager.audioHealthWarning
      )

      // Transcript preview
      TranscriptPreview(
        lines: manager.transcriptLines,
        isIdle: manager.state == .idle
      )

      Divider()

      // Error display
      if case .error(let message) = manager.state {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
        Divider()
      }

      // Actions
      if let url = manager.sessionOutputURL {
        Button {
          let task = Process()
          task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/code")
          task.arguments = [url.path]
          try? task.run()
        } label: {
          Label("Open Session Folder", systemImage: "folder")
        }
        .font(.callout)
      }

      Toggle("Launch at Login", isOn: $settings.launchAtLogin)
        .font(.callout)

      Divider()

      Button {
        Task {
          await manager.shutdown()
          NSApp.terminate(nil)
        }
      } label: {
        Label("Quit Chronicle", systemImage: "power")
      }
      .font(.callout)
      .keyboardShortcut("q")
    }
    .padding()
    .frame(width: 300)
  }

  // MARK: - Subviews

  @ViewBuilder
  private var statusBadge: some View {
    switch manager.state {
    case .idle:
      Text("Idle")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .recording:
      HStack(spacing: 4) {
        Circle()
          .fill(.red)
          .frame(width: 8, height: 8)
        Text("Recording")
          .font(.caption)
          .foregroundStyle(.red)
      }
    case .stopping:
      HStack(spacing: 4) {
        Circle()
          .fill(.orange)
          .frame(width: 8, height: 8)
        Text("Stopping…")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    case .error:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var captureControls: some View {
    if case .recording(let sources) = manager.state {
      Button("Stop") {
        Task { await manager.stopCapture() }
      }
      .font(.callout)
      .foregroundStyle(.red)
      Text("Sources: \(sources.map(\.rawValue).sorted().joined(separator: ", "))")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 8) {
        Button("Mic") {
          Task { await manager.startCapture(sources: [.mic]) }
        }
        Button("System") {
          Task { await manager.startCapture(sources: [.sysaudio]) }
        }
        Button("Both") {
          Task { await manager.startCapture(sources: [.mic, .sysaudio]) }
        }
      }
      .font(.callout)
    }
  }
}
