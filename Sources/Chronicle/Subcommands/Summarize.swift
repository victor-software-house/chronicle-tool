import ChronicleCore
import ArgumentParser
import ChronicleCore
import Foundation

/// Transcript / text summarization via Apple's on-device Foundation Models.
/// Thin CLI veneer over `Core/LLM/Summarizer`.
///
/// Requires Apple Intelligence enabled (macOS 26 + M1+).
struct Summarize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "summarize",
    abstract: "Transcript summarization via FoundationModels with guided generation (free, on-device, requires Apple Intelligence)."
  )

  @Option(name: [.long, .customShort("i")], help: "Input text file. If omitted, reads from stdin.")
  var input: String?

  @Option(name: [.long, .customShort("o")], help: "Output JSON path. If omitted, writes JSON to stdout.")
  var output: String?

  @Option(name: .long, help: "Bullet-point limit.")
  var bullets: Int = 8

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
    let s: ChronicleSummary
    do {
      s = try await Summarizer.summarizeText(text, bullets: bullets)
    } catch let e as ModelHostError {
      FileHandle.standardError.write(Data("[summarize] error: \(e.description)\n".utf8))
      let r = e.remediation
      if !r.isEmpty { FileHandle.standardError.write(Data("[summarize] \(r)\n".utf8)) }
      throw ExitCode(2)
    }
    let elapsed = Date().timeIntervalSince(started)

    struct Doc: Codable {
      let elapsedSeconds: Double
      let inputCharacters: Int
      let tldr: String
      let bullets: [String]
      let decisions: [String]
      let actionItems: [String]
    }
    let doc = Doc(
      elapsedSeconds: elapsed,
      inputCharacters: text.count,
      tldr: s.tldr,
      bullets: s.bullets,
      decisions: s.decisions,
      actionItems: s.actionItems
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(doc)
    if let output {
      try data.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath))
      FileHandle.standardError.write(Data(
        "[summarize] elapsed=\(String(format: "%.2f", elapsed))s bullets=\(s.bullets.count) decisions=\(s.decisions.count) actionItems=\(s.actionItems.count)\n".utf8
      ))
    } else {
      FileHandle.standardOutput.write(data)
      print()
    }
  }
}
