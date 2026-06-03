import ChronicleCore
import ArgumentParser
import ChronicleCore
import Foundation
import ChronicleCore
import NaturalLanguage
import ChronicleCore
import Translation

/// On-device translation via Apple's `Translation` framework. Uses
/// `TranslationSession(installedSource:target:)` for batch translation
/// without a UI host. Requires that the requested language pair has been
/// pre-downloaded via System Settings → Language & Region → Translation
/// Languages.
///
/// References:
/// - https://developer.apple.com/documentation/translation
/// - WWDC24 session 10117, "Meet the Translation API"
/// - scriptingosx/translate-cli (reference impl for non-UI command-line use)
struct Translate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "translate",
    abstract: "On-device translation via Apple Translation framework (free, private, requires pre-downloaded language pair)."
  )

  @Option(name: [.long, .customShort("t")], help: "Target language code (e.g. en, en-US, pt-BR).")
  var to: String

  @Option(name: [.long, .customShort("f")], help: "Source language code. If omitted, auto-detected via NaturalLanguage.")
  var from: String?

  @Option(name: [.long, .customShort("i")], help: "Input text file. If omitted, reads from stdin.")
  var input: String?

  @Option(name: [.long, .customShort("o")], help: "Output text file. If omitted, writes to stdout.")
  var output: String?

  func run() async throws {
    let raw: String
    if let inputPath = input {
      let url = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath)
      raw = try String(contentsOf: url, encoding: .utf8)
    } else {
      var lines: [String] = []
      while let line = readLine(strippingNewline: false) { lines.append(line) }
      raw = lines.joined()
    }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw ValidationError("No input text provided (use --input <file> or pipe via stdin).")
    }

    let sourceLang: Locale.Language
    if let from {
      sourceLang = Locale.Language(identifier: from)
      FileHandle.standardError.write(Data("[translate] source=\(from) (explicit)\n".utf8))
    } else {
      let recognizer = NLLanguageRecognizer()
      recognizer.processString(text)
      guard let dominant = recognizer.dominantLanguage else {
        throw ValidationError("Could not detect source language. Pass --from explicitly.")
      }
      sourceLang = Locale.Language(identifier: dominant.rawValue)
      FileHandle.standardError.write(Data("[translate] source=\(dominant.rawValue) (auto-detected)\n".utf8))
    }

    let targetLang = Locale.Language(identifier: to)
    FileHandle.standardError.write(Data("[translate] target=\(to)\n".utf8))

    if sourceLang.languageCode == targetLang.languageCode {
      FileHandle.standardError.write(Data("[translate] source and target language are the same; emitting input unchanged.\n".utf8))
      try writeOutput(text)
      return
    }

    let session = TranslationSession(installedSource: sourceLang, target: targetLang)
    let started = Date()
    do {
      let response = try await session.translate(text)
      let elapsed = Date().timeIntervalSince(started)
      FileHandle.standardError.write(Data(
        "[translate] elapsed=\(String(format: "%.2f", elapsed))s input=\(text.count) chars output=\(response.targetText.count) chars\n".utf8
      ))
      try writeOutput(response.targetText)
    } catch TranslationError.notInstalled {
      FileHandle.standardError.write(Data("""
        [translate] error: target translation pack not installed.
        Open System Settings → Language & Region → Translation Languages and
        download the language pair (\(sourceLang.languageCode?.identifier ?? "?") → \(targetLang.languageCode?.identifier ?? "?")).
        """.utf8))
      throw ExitCode(2)
    }
  }

  private func writeOutput(_ s: String) throws {
    if let output {
      let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      try s.write(to: url, atomically: true, encoding: .utf8)
    } else {
      print(s)
    }
  }
}
