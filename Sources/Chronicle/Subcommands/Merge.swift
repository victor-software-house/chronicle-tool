import ArgumentParser
import Foundation

/// `chronicle merge` reads one or more source-aware `trace.jsonl` files
/// (preferred) and/or legacy `finals.md` append files, then emits one
/// chronological transcript prefixed with the originating source.
///
/// JSONL input is canonical because it preserves `source`, `sourceKind`,
/// `speakerId`, locale, and wallclock precision. `finals.md` input is
/// supported as a fallback for older runs; source is inferred from the
/// filename and may be overridden with `--source-alias <path>=<name>`.
///
/// Volatile events are excluded by default; pass `--include-volatile` to
/// emit them as well.
struct Merge: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "merge",
    abstract: "Merge source-aware trace.jsonl (preferred) or finals.md inputs into one chronological transcript."
  )

  @Argument(help: "One or more input paths: .jsonl trace files (preferred) or .md/.markdown finals append files.")
  var inputs: [String]

  @Option(name: .long, help: "Override the source label for a given input. Repeatable: --source-alias <path>=<name>.")
  var sourceAlias: [String] = []

  @Option(name: [.long, .customShort("o")], help: "Write merged transcript to this path instead of stdout.")
  var output: String?

  @Option(name: .long, help: "Output format: 'log' (default; '[wallclock] [source] ...') or 'markdown' (markdown table).")
  var format: String = "log"

  @Flag(name: .long, help: "Include volatile events from JSONL inputs (default: finals only).")
  var includeVolatile: Bool = false

  func validate() throws {
    if inputs.isEmpty {
      throw ValidationError("chronicle merge requires at least one input path.")
    }
    for alias in sourceAlias {
      guard alias.contains("=") else {
        throw ValidationError("--source-alias must be <path>=<name> (got: \(alias)).")
      }
    }
    guard MergeOutputFormat(rawValue: format) != nil else {
      throw ValidationError("--format must be 'log' or 'markdown' (got: \(format)).")
    }
  }

  func run() async throws {
    let inputURLs = inputs.map(MergeService.resolve)
    for url in inputURLs {
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw ValidationError("Input file does not exist: \(url.path)")
      }
    }

    let aliasMap = try MergeService.parseAliasMap(sourceAlias)
    let service = MergeService(includeVolatile: includeVolatile, aliasMap: aliasMap)
    let outcome = try service.loadAndSortRecords(inputs: inputURLs)

    for warning in outcome.warnings {
      FileHandle.standardError.write(Data("[merge] \(warning)\n".utf8))
    }

    let outputFormat = MergeOutputFormat(rawValue: format) ?? .log
    let rendered = MergeRenderer.render(records: outcome.records, format: outputFormat)
    if let output = self.output {
      let outURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      let parent = outURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      try rendered.write(to: outURL, atomically: true, encoding: .utf8)
      FileHandle.standardError.write(Data(
        "[merge] wrote \(outcome.records.count) record(s) to \(outURL.path)\n".utf8
      ))
    } else {
      FileHandle.standardOutput.write(Data(rendered.utf8))
    }
  }
}

enum MergeInputFormat {
  case jsonl
  case finalsMarkdown

  static func detect(for url: URL) -> MergeInputFormat {
    switch url.pathExtension.lowercased() {
    case "jsonl": return .jsonl
    case "md", "markdown": return .finalsMarkdown
    default: return .jsonl
    }
  }
}

enum MergeOutputFormat: String {
  case log
  case markdown
}

struct MergedRecord: Equatable, Sendable {
  let wallclock: Date
  let source: String
  let speakerId: String?
  let locale: String?
  let text: String
  /// Tie-break key 1: resolved absolute source path.
  let sourcePath: String
  /// Tie-break key 2: per-source event id (0 for `finals.md` rows that have
  /// no explicit id; finals.md falls back to file order in the absence of
  /// a JSONL eventId).
  let eventId: Int
}

struct MergeOutcome {
  let records: [MergedRecord]
  let warnings: [String]
}

struct MergeService {
  let includeVolatile: Bool
  let aliasMap: [String: String]

  static func resolve(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
  }

  static func parseAliasMap(_ aliases: [String]) throws -> [String: String] {
    var map: [String: String] = [:]
    for raw in aliases {
      guard let eq = raw.firstIndex(of: "=") else {
        throw ValidationError("--source-alias must be <path>=<name> (got: \(raw)).")
      }
      let rawPath = String(raw[..<eq])
      let name = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else {
        throw ValidationError("--source-alias name is empty for path: \(rawPath)")
      }
      let resolved = MergeService.resolve(rawPath).path
      map[resolved] = name
    }
    return map
  }

  func loadAndSortRecords(inputs: [URL]) throws -> MergeOutcome {
    var records: [MergedRecord] = []
    var warnings: [String] = []
    for url in inputs {
      let resolvedPath = url.path
      let aliasOverride = aliasMap[resolvedPath]
      switch MergeInputFormat.detect(for: url) {
      case .jsonl:
        let read = try JSONLTraceSink.readRecoveringEvents(from: url)
        if read.recoveredTrailingLine {
          warnings.append("recovered torn trailing line in \(resolvedPath)")
        }
        for event in read.events {
          if !includeVolatile && !event.isFinal { continue }
          let trimmed = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty { continue }
          records.append(
            MergedRecord(
              wallclock: event.wallclock,
              source: aliasOverride ?? event.source,
              speakerId: event.speakerId,
              locale: event.locale.isEmpty ? nil : event.locale,
              text: trimmed,
              sourcePath: resolvedPath,
              eventId: event.eventId
            )
          )
        }
      case .finalsMarkdown:
        let source = aliasOverride ?? FinalsMarkdownReader.inferSource(for: url)
        let parsed = try FinalsMarkdownReader.read(url: url)
        for (index, entry) in parsed.enumerated() {
          records.append(
            MergedRecord(
              wallclock: entry.wallclock,
              source: source,
              speakerId: nil,
              locale: nil,
              text: entry.text,
              sourcePath: resolvedPath,
              eventId: index + 1
            )
          )
        }
      }
    }

    records.sort { lhs, rhs in
      if lhs.wallclock != rhs.wallclock { return lhs.wallclock < rhs.wallclock }
      if lhs.sourcePath != rhs.sourcePath { return lhs.sourcePath < rhs.sourcePath }
      return lhs.eventId < rhs.eventId
    }
    return MergeOutcome(records: records, warnings: warnings)
  }
}

struct FinalsMarkdownEntry: Equatable {
  let wallclock: Date
  let text: String
}

enum FinalsMarkdownReader {
  /// Parse a `finals.md` produced by `FinalsAppendSink`. Each line looks like:
  ///
  ///     [2026-05-17T10:00:01.123Z] full sentence here
  ///
  /// Tolerates whole-second ISO8601 timestamps. Silently skips malformed
  /// lines and blank lines.
  static func read(url: URL) throws -> [FinalsMarkdownEntry] {
    let contents = try String(contentsOf: url, encoding: .utf8)
    var entries: [FinalsMarkdownEntry] = []
    for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      guard line.hasPrefix("[") else { continue }
      guard let closing = line.firstIndex(of: "]") else { continue }
      let stamp = String(line[line.index(after: line.startIndex)..<closing])
      guard let wallclock = parseWallclock(stamp) else { continue }
      var text = String(line[line.index(after: closing)...])
      text = text.trimmingCharacters(in: .whitespaces)
      if text.isEmpty { continue }
      entries.append(FinalsMarkdownEntry(wallclock: wallclock, text: text))
    }
    return entries
  }

  private static func parseWallclock(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    return whole.date(from: string)
  }

  /// Infer a source label from a `finals.md` path. Known aliases (`mic`,
  /// `sys`, `sysaudio`, `live`) win; otherwise the filename stem is used.
  static func inferSource(for url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent.lowercased()
    let known = ["sysaudio", "mic", "sys", "live"]
    for k in known {
      if stem == k { return k }
      if stem == "finals" || stem == "finals.\(k)" { /* handled below */ }
      let tokens = stem.replacingOccurrences(of: ".", with: "-")
                       .replacingOccurrences(of: "_", with: "-")
                       .split(separator: "-")
                       .map(String.init)
      if tokens.contains(k) { return k }
    }
    return stem
  }
}

enum MergeRenderer {
  static func render(records: [MergedRecord], format: MergeOutputFormat) -> String {
    switch format {
    case .log:
      return renderLog(records: records)
    case .markdown:
      return renderMarkdownTable(records: records)
    }
  }

  static func renderLog(records: [MergedRecord]) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out = ""
    for r in records {
      var line = "[\(formatter.string(from: r.wallclock))] [\(r.source)]"
      var annotations: [String] = []
      if let speaker = r.speakerId, !speaker.isEmpty { annotations.append(speaker) }
      if let locale = r.locale, !locale.isEmpty { annotations.append(locale) }
      if !annotations.isEmpty {
        line += " (\(annotations.joined(separator: ", ")))"
      }
      line += " \(r.text)"
      out += line + "\n"
    }
    return out
  }

  static func renderMarkdownTable(records: [MergedRecord]) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out = "| wallclock | source | speaker | locale | text |\n"
    out += "|---|---|---|---|---|\n"
    for r in records {
      let wall = formatter.string(from: r.wallclock)
      out += "| \(wall) | \(escapeCell(r.source)) | \(escapeCell(r.speakerId ?? "")) | \(escapeCell(r.locale ?? "")) | \(escapeCell(r.text)) |\n"
    }
    return out
  }

  private static func escapeCell(_ s: String) -> String {
    s.replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }
}
