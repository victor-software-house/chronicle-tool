import ArgumentParser
import Foundation
import FoundationModels

/// Transcript / text summarization via Apple's on-device Foundation Models.
/// Uses guided generation with a `Summary` struct so the output is always
/// structured (tl;dr, bullet points, decisions, action items).
///
/// Requires Apple Intelligence enabled.
///
/// References:
/// - https://developer.apple.com/documentation/FoundationModels
/// - WWDC25 session 286, "Meet the Foundation Models framework"
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

    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
      break
    case .unavailable(let reason):
      FileHandle.standardError.write(Data("[summarize] error: Foundation Models unavailable: \(reason)\n".utf8))
      switch reason {
      case .appleIntelligenceNotEnabled:
        FileHandle.standardError.write(Data("[summarize] Enable Apple Intelligence in System Settings → Apple Intelligence & Siri.\n".utf8))
      case .deviceNotEligible:
        FileHandle.standardError.write(Data("[summarize] This Mac is not eligible for Apple Intelligence.\n".utf8))
      case .modelNotReady:
        FileHandle.standardError.write(Data("[summarize] Model not yet downloaded; try again shortly.\n".utf8))
      @unknown default:
        break
      }
      throw ExitCode(2)
    @unknown default:
      throw ExitCode(2)
    }

    let session = LanguageModelSession(
      model: model,
      instructions: """
        You summarize transcripts of meetings, calls, and presentations.
        Be faithful: do not invent facts the text does not state.
        Prefer concrete nouns; avoid vague hedges.
        """
    )

    let prompt = """
      Produce a structured summary of the following text.
      Aim for at most \(bullets) bullets.
      Text:
      ---
      \(text.prefix(30_000))
      ---
      """

    let started = Date()
    let response = try await session.respond(to: prompt, generating: ChronicleSummary.self)
    let elapsed = Date().timeIntervalSince(started)
    let s = response.content

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

@Generable
struct ChronicleSummary {
  @Guide(description: "One-sentence high-level summary of the content.")
  var tldr: String
  @Guide(description: "Short bullet list of the key points.")
  var bullets: [String]
  @Guide(description: "Concrete decisions reached or claims made.")
  var decisions: [String]
  @Guide(description: "Action items, follow-ups, or open questions.")
  var actionItems: [String]
}
