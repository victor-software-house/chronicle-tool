import Foundation

/// Atomically rewrites a single file with the rolling live transcript
/// (accumulated finals + current volatile hypothesis).
///
/// Output shape matches the spike's `--live <path>` behaviour:
///
///     <finalLine1>
///     <finalLine2>
///     → <current volatile>
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

  public func didReceiveVolatile(_ text: String, wallclockOffsetMs: Double) {
    currentVolatile = text
    rewrite()
  }

  public func didReceiveFinal(_ text: String, wallclockOffsetMs: Double, wallclock: Date) {
    finals.append(text)
    currentVolatile = ""
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
}
