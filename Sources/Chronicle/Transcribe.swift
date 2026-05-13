import ArgumentParser
import AVFAudio
import Foundation
import Speech

/// Offline file transcription using Apple's `SpeechAnalyzer` + `SpeechTranscriber`
/// with the `.transcription` preset. Optimised for accuracy on saved WAV/MP3/M4A.
///
/// References:
/// - https://developer.apple.com/documentation/speech/speechanalyzer
/// - WWDC25 session 277, "Bring advanced speech-to-text to your app with SpeechAnalyzer"
/// - spikes/2026-05-13-impl-analysis.md for pattern attribution.
struct Transcribe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "transcribe",
    abstract: "Offline file transcription via Apple SpeechAnalyzer (Neural Engine, on-device, free)."
  )

  @Option(name: [.long, .customShort("i")], help: "Input audio file (wav/m4a/mp3/flac).")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output base path. Writes <out>.txt and <out>.json.")
  var output: String

  @Option(name: .long, help: "Locale, e.g. en-US, pt-BR. Defaults to system locale.")
  var locale: String?

  @Flag(name: .long, help: "Print finalized text to stdout in addition to writing files.")
  var stdout: Bool = false

  func run() async throws {
    guard #available(macOS 26.0, *) else {
      throw ValidationError("This subcommand requires macOS 26.0 or later.")
    }

    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw ValidationError("Input file does not exist: \(inputURL.path)")
    }

    let requestedLocale = Locale(identifier: locale ?? Locale.current.identifier)
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      throw ValidationError("Locale \(requestedLocale.identifier) is not supported by SpeechTranscriber. Try DictationTranscriber.")
    }

    FileHandle.standardError.write(Data("[transcribe] locale=\(supportedLocale.identifier) preset=transcription\n".utf8))

    let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)

    if !(await SpeechTranscriber.installedLocales).contains(supportedLocale) {
      FileHandle.standardError.write(Data("[transcribe] downloading model for \(supportedLocale.identifier)...\n".utf8))
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    // Collect finalized segments with their attributed timing if available.
    struct Segment: Codable {
      let text: String
      let startSeconds: Double?
      let endSeconds: Double?
      let isFinal: Bool
    }
    actor Collector {
      var segments: [Segment] = []
      func append(_ s: Segment) { segments.append(s) }
    }
    let collector = Collector()

    let consumeTask = Task {
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let range = result.range
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(range.end)
        await collector.append(Segment(
          text: text,
          startSeconds: start.isFinite ? start : nil,
          endSeconds: end.isFinite ? end : nil,
          isFinal: result.isFinal
        ))
      }
    }

    let audioFile = try AVAudioFile(forReading: inputURL)
    let started = Date()
    if let last = try await analyzer.analyzeSequence(from: audioFile) {
      try await analyzer.finalizeAndFinish(through: last)
    } else {
      try await analyzer.cancelAndFinishNow()
    }
    try await consumeTask.value
    let elapsed = Date().timeIntervalSince(started)

    let segments = await collector.segments
    let plain = segments
      .filter { $0.isFinal }
      .map { $0.text }
      .joined(separator: " ")

    let outBase = (output as NSString).expandingTildeInPath
    let txtURL = URL(fileURLWithPath: outBase + ".txt")
    let jsonURL = URL(fileURLWithPath: outBase + ".json")

    try plain.write(to: txtURL, atomically: true, encoding: .utf8)

    let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
    struct OutputDoc: Codable {
      let inputPath: String
      let locale: String
      let preset: String
      let audioDurationSeconds: Double
      let elapsedSeconds: Double
      let realtimeFactor: Double
      let segmentCount: Int
      let segments: [Segment]
      let plainText: String
    }
    let doc = OutputDoc(
      inputPath: inputURL.path,
      locale: supportedLocale.identifier,
      preset: "transcription",
      audioDurationSeconds: audioDuration,
      elapsedSeconds: elapsed,
      realtimeFactor: audioDuration > 0 ? audioDuration / elapsed : 0,
      segmentCount: segments.count,
      segments: segments,
      plainText: plain
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(doc).write(to: jsonURL)

    FileHandle.standardError.write(Data(
      "[transcribe] audio=\(String(format: "%.2f", audioDuration))s elapsed=\(String(format: "%.2f", elapsed))s rtf=\(String(format: "%.1f", doc.realtimeFactor))x segments=\(segments.count)\n".utf8
    ))
    FileHandle.standardError.write(Data("[transcribe] wrote \(txtURL.path) + \(jsonURL.path)\n".utf8))

    if stdout {
      print(plain)
    }
  }
}
