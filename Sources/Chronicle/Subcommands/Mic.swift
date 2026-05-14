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

  @Option(name: .long, help: "Also save the raw microphone audio sidecar to this path. Extension depends on --audio-format.")
  var saveAudio: String?

  @Option(name: .long, help: "Audio sidecar codec: 'opus' (Opus 24 kbps in CAF, ADR-0002), 'wav' (lossless), or 'pcm' (rolling raw-PCM scratch, ADR-0002 sec. 2).")
  var audioFormat: String = "wav"

  @Option(name: .long, help: "Opus target bitrate in bps (default 24000). Only meaningful when --audio-format=opus.")
  var opusBitRate: Int = OpusCAFSink.defaultBitRate

  @Option(name: .long, help: "PCM scratch TTL in seconds (default 300). Only meaningful when --audio-format=pcm.")
  var scratchTtl: Double = RollingPCMScratchSink.defaultTTLSeconds

  @Option(name: .long, help: "PCM scratch rotation interval in seconds (default 30). Only meaningful when --audio-format=pcm.")
  var scratchRotate: Double = RollingPCMScratchSink.defaultRotateSeconds

  func run() async throws {
    guard #available(macOS 26.0, *) else {
      throw ValidationError("Requires macOS 26.0+.")
    }

    let requestedLocale = Locale(identifier: locale ?? Locale.current.identifier)
    let engine = try await TranscriptionEngine.make(
      locale: requestedLocale,
      preset: .progressiveTranscription,
      tag: "mic"
    )
    let supported = engine.locale
    let transcriber = engine.transcriber
    let analyzer = engine.analyzer
    guard let analyzerFormat = engine.analyzerFormat else {
      throw ValidationError("Could not resolve a compatible audio format for SpeechAnalyzer.")
    }
    FileHandle.standardError.write(Data("[mic] analyzerFormat=\(analyzerFormat)\n".utf8))

    let micSource = try MicAudioSource(analyzerFormat: analyzerFormat)
    FileHandle.standardError.write(Data("[mic] mic format=\(micSource.micFormat)\n".utf8))

    // Optional raw-audio sidecar.
    let audioSink: AudioSidecarSink? = try makeAudioSidecarSink(
      path: saveAudio,
      analyzerFormat: analyzerFormat
    )

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

    // Compose sidecar sinks.
    var sinks: [TranscriptionSink] = []
    if let path = self.live {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[mic] live transcript file: \(url.path)\n".utf8))
      sinks.append(LiveFileSink(url: url))
    }
    if let path = self.append {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[mic] appending finals to \(url.path)\n".utf8))
      sinks.append(FinalsAppendSink(url: url))
    }
    let composedSinks = sinks

    let consumeTask = Task {
      var lastVolatileLineLength = 0
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let offsetMs = Date().timeIntervalSince(startWall) * 1000.0
        let wallclock = Date()
        await trace.append(TraceEvent(
          wallclockOffsetMs: offsetMs,
          isFinal: result.isFinal,
          text: text
        ))
        if result.isFinal {
          for sink in composedSinks {
            await sink.didReceiveFinal(text, wallclockOffsetMs: offsetMs, wallclock: wallclock)
          }
        } else {
          for sink in composedSinks {
            await sink.didReceiveVolatile(text, wallclockOffsetMs: offsetMs)
          }
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

    // Drain PCM buffers into the optional audio sidecar (Opus / WAV /
    // rolling PCM scratch) concurrently with analyzer consumption.
    // MicAudioSource already converts to analyzerFormat.
    let pcmTask = Task {
      for await ref in micSource.pcmBuffers {
        if let sink = audioSink {
          await sink.append(ref.buffer)
        }
      }
    }

    try await micSource.start()
    FileHandle.standardError.write(Data("[mic] engine started; speak into the mic. Ctrl-C to stop.\n".utf8))

    // Kick off the analyzer over our input sequence.
    try await analyzer.start(inputSequence: micSource.analyzerInputs)

    // Stop trigger: time limit OR SIGINT/SIGTERM.
    if seconds > 0 {
      FileHandle.standardError.write(Data("[mic] will auto-stop after \(seconds)s\n".utf8))
      try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    } else {
      await SignalHandler.waitForTermination()
    }

    FileHandle.standardError.write(Data("\n[mic] stopping...\n".utf8))
    micSource.stop()
    // Bound the analyzer finalize. Falls back to a hard cancel on
    // timeout (e.g. when no valid input ever reached the analyzer).
    do {
      try await withTimeout(seconds: 5.0, label: "analyzer.finalize") {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      }
    } catch is TimeoutError {
      FileHandle.standardError.write(Data(
        "[mic] analyzer.finalize timed out; falling back to cancelAndFinishNow\n".utf8
      ))
      try? await withTimeout(seconds: 2.0, label: "analyzer.cancelAndFinishNow") {
        try await analyzer.cancelAndFinishNow()
      }
    }
    try await consumeTask.value
    _ = await pcmTask.value
    if let audioSink {
      await audioSink.finish()
    }
    for sink in composedSinks {
      await sink.finish()
    }

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

// MARK: - AudioSidecarSink dispatch

func makeAudioSidecarSink(
  path: String?,
  analyzerFormat: AVAudioFormat,
  audioFormat: String? = nil,
  opusBitRate: Int = OpusCAFSink.defaultBitRate,
  scratchTtl: Double = RollingPCMScratchSink.defaultTTLSeconds,
  scratchRotate: Double = RollingPCMScratchSink.defaultRotateSeconds
) throws -> AudioSidecarSink? {
  guard let path else { return nil }
  let expanded = (path as NSString).expandingTildeInPath
  let url = URL(fileURLWithPath: expanded)
  let kind = (audioFormat ?? "wav").lowercased()
  switch kind {
  case "opus":
    FileHandle.standardError.write(Data("[audio] OpusCAFSink -> \(url.path) (\(opusBitRate) bps, source=\(analyzerFormat))\n".utf8))
    return try OpusCAFSink(url: url, sourceFormat: analyzerFormat, bitRate: opusBitRate)
  case "wav":
    FileHandle.standardError.write(Data("[audio] WAVSidecarSink -> \(url.path) (\(analyzerFormat))\n".utf8))
    return try WAVSidecarSink(url: url, sourceFormat: analyzerFormat)
  case "pcm":
    FileHandle.standardError.write(Data("[audio] RollingPCMScratchSink -> \(url.path)/ (ttl=\(scratchTtl)s rotate=\(scratchRotate)s)\n".utf8))
    return try RollingPCMScratchSink(
      base: url,
      sourceFormat: analyzerFormat,
      ttl: scratchTtl,
      rotateInterval: scratchRotate
    )
  default:
    throw ValidationError("--audio-format must be one of {opus, wav, pcm}; got '\(kind)'")
  }
}
