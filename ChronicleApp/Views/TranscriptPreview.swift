import SwiftUI

/// Scrollable live transcript lines with optional speaker labels.
struct TranscriptPreview: View {
  let lines: [TranscriptLine]
  let isIdle: Bool

  var body: some View {
    if isIdle && lines.isEmpty {
      Text("No active session")
        .foregroundStyle(.secondary)
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
              HStack(alignment: .top, spacing: 4) {
                if let speaker = line.speakerId {
                  Text("[\(speaker)]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
                }
                Text(line.text)
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
              }
              .id(line.id)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .onChange(of: lines.last?.id) { _, newID in
          if let id = newID {
            proxy.scrollTo(id, anchor: .bottom)
          }
        }
      }
    }
  }
}
