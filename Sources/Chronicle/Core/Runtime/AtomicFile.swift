import Foundation

/// File-system primitives used by sidecar sinks.
///
/// - `atomicWrite`: rewrite an entire file via `String.write(to:atomically:)`,
///   matching the live-snapshot pattern used by `--live`.
/// - `appendLine`: open-append-close per call; line-terminated. Matches the
///   `--append` pattern used by `--append <finals.md>`.
/// - `appendJSONLines`: same as `appendLine` but encodes a `Codable` value to
///   compact JSON first. Foundation of the FR-2 `JSONLTraceSink`.
public enum AtomicFile {
  /// Rewrite `url` with `contents` using `String.write(to:atomically:)`.
  /// Creates the file if missing, replaces it if present.
  public static func atomicWrite(_ contents: String, to url: URL) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Ensure the parent file exists (zero-byte if missing) and is openable for
  /// appending. Useful at daemon startup so the first append succeeds.
  public static func ensureExists(_ url: URL) {
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
  }

  /// Append `line` (with trailing newline if not already present) to `url`.
  /// Opens, seeks-to-end, writes, closes per call. Crash-safe at the line
  /// boundary: a `SIGKILL` mid-write leaves at most a torn final line.
  public static func appendLine(_ line: String, to url: URL) throws {
    ensureExists(url)
    let terminated = line.hasSuffix("\n") ? line : line + "\n"
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(terminated.utf8))
  }

  /// JSON-encode `value` (compact, sorted keys) and append as one line. The
  /// trace format expected by `JSONLTraceSink` and downstream `jq` tooling.
  public static func appendJSONLine<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder? = nil) throws {
    let enc = encoder ?? {
      let e = JSONEncoder()
      e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return e
    }()
    let data = try enc.encode(value)
    guard let json = String(data: data, encoding: .utf8) else { return }
    try appendLine(json, to: url)
  }
}
