import ArgumentParser
import AVFoundation
import Foundation
import Speech

#if canImport(Darwin)
import Darwin
#endif

/// Live microphone transcription via `AVAudioEngine` input tap +
/// `SpeechAnalyzer` `.progressiveTranscription` preset.
///
/// Requires:
/// - macOS 26.0+ (for SpeechAnalyzer).
/// - `NSMicrophoneUsageDescription` baked into the binary via Info.plist
///   (Package.swift wires `-sectcreate __TEXT __info_plist Info.plist`).
/// - TCC permission for Microphone (granted via System Settings → Privacy
///   & Security → Microphone, or the first-run prompt).
///
/// Reference patterns: swift-scribe's `Recorder.swift` for the
/// AVAudioEngine→SpeechAnalyzer plumbing.
struct Mic: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mic",
    abstract: "Live microphone transcription via AVAudioEngine + SpeechAnalyzer progressive preset (Neural Engine, on-device)."
  )

  @Option(name: .long, help: "Locale, e.g. en-US.")
  var locale: String?

  @Option(name: [.long, .customShort("o")], help: "Optional output JSON path (volatile + final event trace).")
  var output: String?

  @Option(name: .long, help: "Stop after this many seconds (0 = run until SIGINT).")
  var seconds: Int = 0

  @Flag(name: .long, help: "Render volatile updates inline (TTY repaint) instead of one line each.")
  var inline: Bool = false

  @Option(name: .long, help: "Append each finalized segment (with timestamp) to this file. Survives kill / SIGTERM.")
  var append: String?

  @Option(name: .long, help: "Rewrite this file on every event with the rolling live transcript (finals + current volatile). Updates every ~150 ms.")
  var live: String?

  @Option(name: .long, help: "Also save the raw microphone audio to this WAV file (16 kHz mono Float32, lossless).")
  var saveAudio: String?

  func run() async throws {
    guard #available(macOS 26.0, *) else {
      throw ValidationError("Requires macOS 26.0+.")
    }

    let requestedLocale = Locale(identifier: locale ?? Locale.current.identifier)
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      throw ValidationError("Locale \(requestedLocale.identifier) is not supported by SpeechTranscriber.")
    }

    let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
    if !(await SpeechTranscriber.installedLocales).contains(supported) {
      FileHandle.standardError.write(Data("[mic] downloading model for \(supported.identifier)...\n".utf8))
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }
    }
    FileHandle.standardError.write(Data("[mic] locale=\(supported.identifier) preset=progressiveTranscription\n".utf8))

    // Pick the analyzer's preferred audio format and force the engine into it.
    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      throw ValidationError("Could not resolve a compatible audio format for SpeechAnalyzer.")
    }
    FileHandle.standardError.write(Data("[mic] analyzerFormat=\(analyzerFormat)\n".utf8))

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    FileHandle.standardError.write(Data("[mic] mic format=\(inputFormat)\n".utf8))

    let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
    guard converter != nil else {
      throw ValidationError("Could not build AVAudioConverter from mic format to analyzer format.")
    }

    // Optional raw-audio sidecar.
    var audioFile: AVAudioFile? = nil
    if let saveAudio {
      let url = URL(fileURLWithPath: (saveAudio as NSString).expandingTildeInPath)
      let settings = analyzerFormat.settings
      audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: analyzerFormat.commonFormat, interleaved: analyzerFormat.isInterleaved)
      FileHandle.standardError.write(Data("[mic] saving audio to \(url.path) (\(analyzerFormat))\n".utf8))
    }
    let audioFileBox = AudioFileBox(file: audioFile)

    let (input, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)

    struct TraceEvent: Codable, Sendable {
      let wallclockOffsetMs: Double
      let isFinal: Bool
      let text: String
    }
    actor TraceCollector {
      var events: [TraceEvent] = []
      func append(_ e: TraceEvent) { events.append(e) }
    }
    let trace = TraceCollector()
    let startWall = Date()

    let inline = self.inline
    let appendPath = self.append.map { ($0 as NSString).expandingTildeInPath }
    let appendURL = appendPath.map { URL(fileURLWithPath: $0) }
    if let url = appendURL {
      AtomicFile.ensureExists(url)
      FileHandle.standardError.write(Data("[mic] appending finals to \(url.path)\n".utf8))
    }
    let livePath = self.live.map { ($0 as NSString).expandingTildeInPath }
    let liveURL = livePath.map { URL(fileURLWithPath: $0) }
    if let url = liveURL {
      FileHandle.standardError.write(Data("[mic] live transcript file: \(url.path)\n".utf8))
    }
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    // Rolling buffers for live-file rendering.
    actor LiveState {
      var finals: [String] = []
      var currentVolatile: String = ""
      func addFinal(_ s: String) {
        finals.append(s)
        currentVolatile = ""
      }
      func setVolatile(_ s: String) {
        currentVolatile = s
      }
      func snapshot() -> String {
        let finalBlock = finals.joined(separator: "\n")
        if currentVolatile.isEmpty { return finalBlock }
        if finalBlock.isEmpty { return "→ \(currentVolatile)" }
        return finalBlock + "\n→ " + currentVolatile
      }
    }
    let liveState = LiveState()

    let consumeTask = Task {
      var lastVolatileLineLength = 0
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let offsetMs = Date().timeIntervalSince(startWall) * 1000.0
        await trace.append(TraceEvent(
          wallclockOffsetMs: offsetMs,
          isFinal: result.isFinal,
          text: text
        ))
        if result.isFinal {
          await liveState.addFinal(text)
          if let url = appendURL {
            let line = "[\(isoFormatter.string(from: Date()))] \(text)"
            try? AtomicFile.appendLine(line, to: url)
          }
        } else {
          await liveState.setVolatile(text)
        }
        if let url = liveURL {
          let snapshot = await liveState.snapshot()
          try? AtomicFile.atomicWrite(snapshot, to: url)
        }
        if inline {
          if result.isFinal {
            // Clear any in-progress volatile line then print final on its own line.
            if lastVolatileLineLength > 0 {
              fputs("\r" + String(repeating: " ", count: lastVolatileLineLength) + "\r", stdout)
              lastVolatileLineLength = 0
            }
            print("\u{1b}[32mFINAL\u{1b}[0m \(text)")
          } else {
            let line = "\u{1b}[33mvolatile\u{1b}[0m \(text)"
            fputs("\r\(line)", stdout)
            fflush(stdout)
            lastVolatileLineLength = line.count
          }
        } else {
          if result.isFinal {
            print("\u{1b}[32mFINAL\u{1b}[0m \(text)")
          } else {
            print("\u{1b}[33mvolatile\u{1b}[0m \(text)")
          }
        }
      }
    }

    // Wire the engine tap. Use the mic's native format on the tap, convert on push.
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [analyzerFormat, audioFileBox] buffer, _ in
      guard let convertedFrameCapacity = AVAudioFrameCount(
        Double(buffer.frameLength) * analyzerFormat.sampleRate / inputFormat.sampleRate
      ) as AVAudioFrameCount?,
            convertedFrameCapacity > 0,
            let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: convertedFrameCapacity)
      else { return }

      let conv = AVAudioConverter(from: inputFormat, to: analyzerFormat)
      var error: NSError?
      let status = conv?.convert(to: converted, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }
      if status == .haveData {
        builder.yield(AnalyzerInput(buffer: converted))
        // Sidecar audio write (lossless 16kHz Float32).
        if let file = audioFileBox.file {
          try? file.write(from: converted)
        }
      }
    }

    engine.prepare()
    try engine.start()
    FileHandle.standardError.write(Data("[mic] engine started; speak into the mic. Ctrl-C to stop.\n".utf8))

    // Kick off the analyzer over our input sequence.
    try await analyzer.start(inputSequence: input)

    // Stop trigger: time limit OR SIGINT/SIGTERM.
    if seconds > 0 {
      FileHandle.standardError.write(Data("[mic] will auto-stop after \(seconds)s\n".utf8))
      try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    } else {
      await SignalHandler.waitForTermination()
    }

    FileHandle.standardError.write(Data("\n[mic] stopping...\n".utf8))
    engine.stop()
    inputNode.removeTap(onBus: 0)
    builder.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    try await consumeTask.value

    let events = await trace.events
    let volatileCount = events.filter { !$0.isFinal }.count
    let finalCount = events.filter { $0.isFinal }.count
    FileHandle.standardError.write(Data(
      "[mic] done. volatile=\(volatileCount) final=\(finalCount)\n".utf8
    ))

    if let output {
      struct Doc: Codable {
        let locale: String
        let preset: String
        let elapsedSeconds: Double
        let volatileEvents: Int
        let finalEvents: Int
        let events: [TraceEvent]
      }
      let doc = Doc(
        locale: supported.identifier,
        preset: "progressiveTranscription",
        elapsedSeconds: Date().timeIntervalSince(startWall),
        volatileEvents: volatileCount,
        finalEvents: finalCount,
        events: events
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(doc).write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath))
      FileHandle.standardError.write(Data("[mic] wrote \(output)\n".utf8))
    }
  }
}

/// Sendable wrapper so the audio-tap closure can hold a reference to an
/// AVAudioFile without a Sendable warning.
private final class AudioFileBox: @unchecked Sendable {
  let file: AVAudioFile?
  init(file: AVAudioFile?) { self.file = file }
}
