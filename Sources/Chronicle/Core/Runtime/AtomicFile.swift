import Foundation

#if canImport(Darwin)
import Darwin
#endif

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
  /// Opens, append-writes, closes per call. Darwin uses `O_APPEND` plus
  /// `flock(LOCK_EX)` so concurrent processes cannot interleave lines.
  /// Crash-safe at the line boundary: a `SIGKILL` mid-write leaves at most a
  /// torn final line.
  public static func appendLine(_ line: String, to url: URL) throws {
    ensureExists(url)
    let terminated = line.hasSuffix("\n") ? line : line + "\n"
#if canImport(Darwin)
    try appendLineDarwin(terminated, to: url)
#else
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(terminated.utf8))
#endif
  }

#if canImport(Darwin)
  private static func appendLineDarwin(_ terminated: String, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard fd >= 0 else { throw posixError() }
    defer { close(fd) }

    while flock(fd, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw posixError()
    }
    defer { flock(fd, LOCK_UN) }

    let bytes = Array(terminated.utf8)
    try bytes.withUnsafeBytes { rawBuffer in
      var remaining = rawBuffer.count
      var pointer = rawBuffer.baseAddress
      while remaining > 0 {
        let written = write(fd, pointer, remaining)
        if written < 0 {
          if errno == EINTR { continue }
          throw posixError()
        }
        if written == 0 {
          throw POSIXError(.EIO)
        }
        remaining -= written
        pointer = pointer?.advanced(by: written)
      }
    }
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
#endif

  /// JSON-encode `value` (compact, sorted keys) and append as one line. The
  /// trace format expected by `JSONLTraceSink` and downstream `jq` tooling.
  public static func appendJSONLine<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder? = nil) throws {
    let enc = encoder ?? {
      let e = JSONEncoder()
      e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return e
    }()
    let data = try enc.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw POSIXError(.EILSEQ)
    }
    try appendLine(json, to: url)
  }
}
