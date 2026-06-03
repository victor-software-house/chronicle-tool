import SwiftUI

/// Displays session duration, active sources, and speaker count.
struct SessionInfoView: View {
  let duration: Duration?
  let activeSources: Set<CaptureSource>
  let speakerCount: Int
  let diarizationEnabled: Bool

  var body: some View {
    if !activeSources.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Image(systemName: "clock")
            .foregroundStyle(.secondary)
          Text(formattedDuration)
            .font(.system(.caption, design: .monospaced))
        }

        HStack {
          Image(systemName: "waveform")
            .foregroundStyle(.secondary)
          Text(sourcesLabel)
            .font(.caption)
        }

        if diarizationEnabled && speakerCount > 0 {
          HStack {
            Image(systemName: "person.2")
              .foregroundStyle(.secondary)
            Text("\(speakerCount) speaker\(speakerCount == 1 ? "" : "s")")
              .font(.caption)
          }
        }
      }
    }
  }

  private var formattedDuration: String {
    guard let d = duration else { return "00:00:00" }
    let total = Int(d.components.seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
  }

  private var sourcesLabel: String {
    let names = activeSources.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
    return names.joined(separator: " + ")
  }
}
