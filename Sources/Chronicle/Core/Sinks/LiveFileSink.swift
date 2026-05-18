import Foundation

/// Atomically rewrites a single file with the rolling live transcript
/// (accumulated finals + current volatile hypothesis).
///
/// Output shape — clean, readable, `tail -f` friendly:
///
///     [05:12:03] [S0] Good morning everyone.
///     [05:12:08] [S1] Thank you Sarah.
///     → I want to add some technical con
///
/// Finals are timestamped and speaker-labelled. The last line (prefixed `→`)
/// is the current volatile partial, replaced on every event. When no speech
/// is active the volatile line disappears.
///
/// Re-renders on every event via `AtomicFile.atomicWrite`. Survives crashes
/// at any point: the file is replaced atomically per write.
public actor LiveFileSink: TranscriptionSink {
  private let url: URL
  private var finals: [String] = []
  private var currentVolatile: String = ""

  public init(url: URL) {
    self.url = url
  }

  public func didReceiveResult(
    _ text: String,
    isFinal: Bool,
    wallclockOffsetMs: Double,
    wallclock: Date,
    audioRange: TraceAudioRange?,
    speakerId: String?
  ) {
    if isFinal {
      let ts = Self.formatTime(wallclock)
      let speaker = speakerId.map { " [\($0)]" } ?? ""
      finals.append("[\(ts)]\(speaker) \(text)")
      currentVolatile = ""
    } else {
      currentVolatile = text
    }
    rewrite()
  }

  public func finish() {
    rewrite()
  }

  private func rewrite() {
    let finalBlock = finals.joined(separator: "\n")
    let snapshot: String
    if currentVolatile.isEmpty {
      snapshot = finalBlock
    } else if finalBlock.isEmpty {
      snapshot = "→ \(currentVolatile)"
    } else {
      snapshot = finalBlock + "\n→ " + currentVolatile
    }
    try? AtomicFile.atomicWrite(snapshot, to: url)
  }

  private static func formatTime(_ date: Date) -> String {
    let cal = Calendar.current
    let h = cal.component(.hour, from: date)
    let m = cal.component(.minute, from: date)
    let s = cal.component(.second, from: date)
    return String(format: "%02d:%02d:%02d", h, m, s)
  }
}
