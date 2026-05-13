import ArgumentParser
import Foundation
import FoundationModels

/// Content tagging via Apple's on-device Foundation Models framework using
/// the built-in `.contentTagging` adapter. Outputs topic tags, entities,
/// and actions for a given text blob with guided generation.
///
/// Requires:
/// - Apple Intelligence enabled in System Settings.
/// - macOS 26 / Tahoe + Apple Silicon (M1+).
///
/// References:
/// - https://developer.apple.com/documentation/FoundationModels
/// - WWDC25 session 286, "Meet the Foundation Models framework"
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

    let model = SystemLanguageModel(useCase: .contentTagging)
    switch model.availability {
    case .available:
      break
    case .unavailable(let reason):
      FileHandle.standardError.write(Data("[tag] error: Foundation Models unavailable: \(reason)\n".utf8))
      switch reason {
      case .appleIntelligenceNotEnabled:
        FileHandle.standardError.write(Data("[tag] Enable Apple Intelligence in System Settings → Apple Intelligence & Siri.\n".utf8))
      case .deviceNotEligible:
        FileHandle.standardError.write(Data("[tag] This Mac is not eligible for Apple Intelligence.\n".utf8))
      case .modelNotReady:
        FileHandle.standardError.write(Data("[tag] Model not yet downloaded; try again shortly.\n".utf8))
      @unknown default:
        break
      }
      throw ExitCode(2)
    @unknown default:
      throw ExitCode(2)
    }

    let session = LanguageModelSession(model: model)

    let prompt = """
      Tag the following text. Return at most \(limit) items per category.
      Be specific and concrete; prefer multi-word topics ("speech recognition" over "speech").
      Text:
      ---
      \(text.prefix(20_000))
      ---
      """

    let started = Date()
    let response = try await session.respond(to: prompt, generating: ChronicleTagSet.self)
    let elapsed = Date().timeIntervalSince(started)
    let tags = response.content

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

@Generable
struct ChronicleTagSet {
  @Guide(description: "Topic tags identifying the subject matter of the text.")
  var topics: [String]
  @Guide(description: "Named entities (people, products, organisations, places).")
  var entities: [String]
  @Guide(description: "Actions or verbs that summarise what happened in the text.")
  var actions: [String]
}
