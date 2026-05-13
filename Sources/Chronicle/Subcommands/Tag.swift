import ArgumentParser
import Foundation

/// Content tagging via Apple's on-device Foundation Models framework using
/// the built-in `.contentTagging` adapter. Thin CLI veneer over
/// `Core/LLM/ContentTagger`.
///
/// Requires Apple Intelligence enabled (macOS 26 + M1+).
struct Tag: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tag",
    abstract: "Content tagging via FoundationModels content-tagging adapter (free, on-device, requires Apple Intelligence)."
  )

  @Option(name: [.long, .customShort("i")], help: "Input text file. If omitted, reads from stdin.")
  var input: String?

  @Option(name: [.long, .customShort("o")], help: "Output JSON path. If omitted, writes JSON to stdout.")
  var output: String?

  @Option(name: .long, help: "Maximum number of tags to return.")
  var limit: Int = 15

  func run() async throws {
    let raw: String
    if let inputPath = input {
      raw = try String(contentsOf: URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath), encoding: .utf8)
    } else {
      var lines: [String] = []
      while let line = readLine(strippingNewline: false) { lines.append(line) }
      raw = lines.joined()
    }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw ValidationError("No input text provided (use --input <file> or pipe via stdin).")
    }

    let started = Date()
    let tags: ChronicleTagSet
    do {
      tags = try await ContentTagger.tagText(text, limit: limit)
    } catch let e as ModelHostError {
      FileHandle.standardError.write(Data("[tag] error: \(e.description)\n".utf8))
      let r = e.remediation
      if !r.isEmpty { FileHandle.standardError.write(Data("[tag] \(r)\n".utf8)) }
      throw ExitCode(2)
    }
    let elapsed = Date().timeIntervalSince(started)

    struct Doc: Codable {
      let elapsedSeconds: Double
      let inputCharacters: Int
      let topics: [String]
      let entities: [String]
      let actions: [String]
    }
    let doc = Doc(
      elapsedSeconds: elapsed,
      inputCharacters: text.count,
      topics: tags.topics,
      entities: tags.entities,
      actions: tags.actions
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(doc)
    if let output {
      try data.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath))
      FileHandle.standardError.write(Data("[tag] elapsed=\(String(format: "%.2f", elapsed))s topics=\(tags.topics.count) entities=\(tags.entities.count) actions=\(tags.actions.count)\n".utf8))
    } else {
      FileHandle.standardOutput.write(data)
      print()
    }
  }
}
