import SwiftUI
import ChronicleCore

@main
struct ChronicleApp: App {
  var body: some Scene {
    MenuBarExtra {
      VStack(alignment: .leading, spacing: 8) {
        Text("Chronicle")
          .font(.headline)

        Divider()

        Text("No active session")
          .foregroundStyle(.secondary)
          .font(.caption)

        Divider()

        Button("Quit Chronicle") {
          NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
      }
      .padding()
      .frame(width: 280)
    } label: {
      Image(systemName: "waveform")
    }
    .menuBarExtraStyle(.window)
  }
}
