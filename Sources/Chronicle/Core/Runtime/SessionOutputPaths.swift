import Foundation

/// Auto-generated output paths for a live capture session.
///
/// When the operator does not specify explicit `--output`, `--append`, or
/// `--live` paths, Chronicle creates a timestamped session directory under
/// `~/Documents/chronicle/<source>/` so every session is captured by default
/// with zero overhead to the operator.
///
/// Layout:
/// ```
/// ~/Documents/chronicle/mic/2026-05-18T05-12-03/
///   trace.jsonl      # full JSONL trace (volatile + final + metadata)
///   finals.md        # append-only finalized segments
///   live.log         # atomically-rewritten streaming transcript
/// ```
public struct SessionOutputPaths {
  public let trace: URL
  public let finals: URL
  public let live: URL
  public let sessionDir: URL

  /// Build default output paths for a source (e.g. "mic", "sysaudio").
  /// Creates the session directory if it does not exist.
  public static func defaults(source: String) throws -> SessionOutputPaths {
    let base = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Documents/chronicle/\(source)", isDirectory: true)
    let ts = Self.sessionTimestamp()
    let dir = base.appendingPathComponent(ts, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return SessionOutputPaths(
      trace: dir.appendingPathComponent("trace.jsonl"),
      finals: dir.appendingPathComponent("finals.md"),
      live: dir.appendingPathComponent("live.log"),
      sessionDir: dir
    )
  }

  /// Resolve output paths: use explicit CLI overrides where provided,
  /// fall back to session defaults for the rest.
  public static func resolve(
    source: String,
    outputOverride: String?,
    appendOverride: String?,
    liveOverride: String?
  ) throws -> SessionOutputPaths {
    let defaults = try Self.defaults(source: source)
    return SessionOutputPaths(
      trace: outputOverride.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaults.trace,
      finals: appendOverride.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaults.finals,
      live: liveOverride.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaults.live,
      sessionDir: defaults.sessionDir
    )
  }

  private static func sessionTimestamp() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    df.timeZone = TimeZone.current
    return df.string(from: Date())
  }
}
