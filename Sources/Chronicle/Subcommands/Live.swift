import ArgumentParser
import AVFAudio
import Foundation
import Speech

/// Progressive (low-latency) transcription using the
/// `.progressiveTranscription` preset of `SpeechTranscriber`.
///
/// This subcommand uses **file input** rather than a live microphone
/// stream. The `.progressiveTranscription` preset is what makes transcription
/// "live": it emits volatile partial results as audio flows through and
/// finalises them later. The input stream itself can be a microphone, a
/// growing WAV, or — as here — a regular file fed buffer-by-buffer. The
/// preset behaviour and result-stream semantics are identical.
///
/// Why file input here: a CLI tool tapping `AVAudioEngine.inputNode` needs
/// an `Info.plist` with `NSMicrophoneUsageDescription`, code-signing, and a
/// TCC prompt. We document that path but ship the file-driven demo first to
/// validate the preset and the volatile/final result split.
///
/// References:
/// - https://developer.apple.com/documentation/speech/speechtranscriber/preset/progressivetranscription
/// - WWDC25 session 277, "Bring advanced speech-to-text to your app with SpeechAnalyzer"
struct Live: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "live",
    abstract: "Progressive (live-mode) transcription via SpeechAnalyzer .progressiveTranscription preset, file-driven for now."
  )

  @Option(name: [.long, .customShort("i")], help: "Input audio file to stream through the analyzer.")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Optional output JSON path (volatile + final result trace).")
  var output: String?

  @Option(name: .long, help: "Locale, e.g. en-US.")
  var locale: String?

  func run() async throws {
    guard #available(macOS 26.0, *) else {
      throw ValidationError("Requires macOS 26.0+.")
    }
    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw ValidationError("Input file does not exist: \(inputURL.path)")
    }

    let requestedLocale = Locale(identifier: locale ?? Locale.current.identifier)
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      throw ValidationError("Locale \(requestedLocale.identifier) is not supported by SpeechTranscriber.")
    }

    let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
    if !(await SpeechTranscriber.installedLocales).contains(supported) {
      FileHandle.standardError.write(Data("[live] downloading model for \(supported.identifier)...\n".utf8))
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }
    }
    FileHandle.standardError.write(Data("[live] locale=\(supported.identifier) preset=progressiveTranscription\n".utf8))

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    struct TraceEvent: Codable {
      let wallclockOffsetMs: Double
      let audioRangeStart: Double
      let audioRangeEnd: Double
      let isFinal: Bool
      let text: String
    }
    actor TraceCollector {
      var events: [TraceEvent] = []
      func append(_ e: TraceEvent) { events.append(e) }
    }
    let trace = TraceCollector()
    let startWall = Date()

    let consumeTask = Task {
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let offset = Date().timeIntervalSince(startWall) * 1000.0
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(result.range.end)
        await trace.append(TraceEvent(
          wallclockOffsetMs: offset,
          audioRangeStart: start.isFinite ? start : -1,
          audioRangeEnd: end.isFinite ? end : -1,
          isFinal: result.isFinal,
          text: text
        ))
        if result.isFinal {
          print("\u{1b}[32mFINAL\u{1b}[0m \(String(format: "%6.2f", start))s: \(text)")
        } else {
          print("\u{1b}[33mvolatile\u{1b}[0m \(String(format: "%6.2f", start))s: \(text)")
        }
      }
    }

    let audioFile = try AVAudioFile(forReading: inputURL)
    let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
    FileHandle.standardError.write(Data("[live] audio=\(String(format: "%.2f", audioDuration))s — streaming through analyzer\n".utf8))

    let startedStreaming = Date()
    if let last = try await analyzer.analyzeSequence(from: audioFile) {
      try await analyzer.finalizeAndFinish(through: last)
    } else {
      try await analyzer.cancelAndFinishNow()
    }
    try await consumeTask.value
    let elapsed = Date().timeIntervalSince(startedStreaming)

    let events = await trace.events
    let volatileCount = events.filter { !$0.isFinal }.count
    let finalCount = events.filter { $0.isFinal }.count

    FileHandle.standardError.write(Data(
      "[live] elapsed=\(String(format: "%.2f", elapsed))s audio=\(String(format: "%.2f", audioDuration))s rtf=\(String(format: "%.1f", audioDuration / elapsed))x volatile=\(volatileCount) final=\(finalCount)\n".utf8
    ))

    if let output {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      struct Doc: Codable {
        let inputPath: String
        let locale: String
        let preset: String
        let audioDurationSeconds: Double
        let elapsedSeconds: Double
        let realtimeFactor: Double
        let volatileEvents: Int
        let finalEvents: Int
        let events: [TraceEvent]
      }
      let doc = Doc(
        inputPath: inputURL.path,
        locale: supported.identifier,
        preset: "progressiveTranscription",
        audioDurationSeconds: audioDuration,
        elapsedSeconds: elapsed,
        realtimeFactor: audioDuration / elapsed,
        volatileEvents: volatileCount,
        finalEvents: finalCount,
        events: events
      )
      try encoder.encode(doc).write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath))
      FileHandle.standardError.write(Data("[live] wrote \(output)\n".utf8))
    }
  }
}
