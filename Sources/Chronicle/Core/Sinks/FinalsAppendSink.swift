import Foundation

/// Appends one timestamped line per final segment.
///
/// Output shape matches the spike's `--append <path>` behaviour:
///
///     [2026-05-13T23:10:45.123Z] full sentence here
///     [2026-05-13T23:10:51.987Z] next sentence here
///
/// Each line is appended via `AtomicFile.appendLine` (open-append-close).
/// Crash-safe at line granularity: `SIGKILL` mid-write leaves at most a
/// torn trailing line; every prior line is intact.
public actor FinalsAppendSink: TranscriptionSink {
  private let url: URL
  private let isoFormatter: ISO8601DateFormatter

  public init(url: URL) {
    self.url = url
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.isoFormatter = f
    AtomicFile.ensureExists(url)
  }

  public func didReceiveFinal(_ text: String, wallclockOffsetMs: Double, wallclock: Date) {
    let line = "[\(isoFormatter.string(from: wallclock))] \(text)"
    try? AtomicFile.appendLine(line, to: url)
  }
}
