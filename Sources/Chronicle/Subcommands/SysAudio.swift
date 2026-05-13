import ArgumentParser
import AVFoundation
import Foundation
import Speech

/// Live system-audio transcription via `SCStream` + `SpeechAnalyzer`
/// progressive preset. Captures every app's audio output (system mix) and
/// produces the same sidecar artefacts as `chronicle mic` (live snapshot
/// + timestamped finals).
///
/// Requires Screen Recording permission (`NSScreenCaptureUsageDescription`
/// is set in Info.plist; macOS will prompt on first run).
struct SysAudio: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sysaudio",
    abstract: "Live system-audio transcription via ScreenCaptureKit + SpeechAnalyzer (on-device, requires Screen Recording permission)."
  )

  @Option(name: .long, help: "Locale, e.g. en-US. Locale auto-detect (ADR-0003) lands with FR-6/P4.")
  var locale: String?

  @Option(name: .long, help: "Stop after this many seconds (0 = run until SIGINT/SIGTERM).")
  var seconds: Int = 0

  @Option(name: .long, help: "Append each finalized segment (with timestamp) to this file.")
  var append: String?

  @Option(name: .long, help: "Rewrite this file on every event with the rolling live transcript.")
  var live: String?

  @Option(name: .long, help: "Also save the raw system-audio capture to this WAV file (16 kHz Int16 mono).")
  var saveAudio: String?

  @Flag(name: .long, help: "Include audio from this process. Default is to exclude (prevents feedback loops).")
  var includeSelfAudio: Bool = false

  @Flag(name: .long, help: "Render volatile updates inline (TTY repaint) instead of one line each.")
  var inline: Bool = false

  @Flag(name: .long, help: "Log SysAudioSource buffer diagnostics every ~1.2s (buffer count + peak amplitude). Useful when audio appears silent.")
  var verbose: Bool = false

  func run() async throws {
    guard #available(macOS 26.0, *) else {
      throw ValidationError("Requires macOS 26.0+.")
    }

    let requestedLocale = Locale(identifier: locale ?? Locale.current.identifier)
    let txEngine = try await TranscriptionEngine.make(
      locale: requestedLocale,
      preset: .progressiveTranscription,
      tag: "sysaudio"
    )
    let transcriber = txEngine.transcriber
    let analyzer = txEngine.analyzer
    guard let analyzerFormat = txEngine.analyzerFormat else {
      throw ValidationError("Could not resolve a compatible audio format for SpeechAnalyzer.")
    }
    FileHandle.standardError.write(Data("[sysaudio] analyzerFormat=\(analyzerFormat)\n".utf8))

    let sysSource = SysAudioSource(
      analyzerFormat: analyzerFormat,
      excludeCurrentProcessAudio: !includeSelfAudio
    )
    sysSource.verbose = verbose

    // Optional raw-audio sidecar (writes the analyzer-format buffer; not the
    // SCStream native format).
    var audioFile: AVAudioFile? = nil
    if let saveAudio {
      let url = URL(fileURLWithPath: (saveAudio as NSString).expandingTildeInPath)
      let settings = analyzerFormat.settings
      audioFile = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: analyzerFormat.commonFormat,
        interleaved: analyzerFormat.isInterleaved
      )
      FileHandle.standardError.write(Data("[sysaudio] saving audio to \(url.path) (\(analyzerFormat))\n".utf8))
    }
    let audioFileBox = SysAudioFileBox(file: audioFile)

    // Compose sidecar sinks.
    var sinks: [TranscriptionSink] = []
    if let path = self.live {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[sysaudio] live transcript file: \(url.path)\n".utf8))
      sinks.append(LiveFileSink(url: url))
    }
    if let path = self.append {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[sysaudio] appending finals to \(url.path)\n".utf8))
      sinks.append(FinalsAppendSink(url: url))
    }
    let composedSinks = sinks

    let inline = self.inline
    let startWall = Date()

    let consumeTask = Task {
      var lastVolatileLineLength = 0
      var volatileCount = 0
      var finalCount = 0
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let offsetMs = Date().timeIntervalSince(startWall) * 1000.0
        let wallclock = Date()
        if result.isFinal {
          finalCount += 1
          for sink in composedSinks {
            await sink.didReceiveFinal(text, wallclockOffsetMs: offsetMs, wallclock: wallclock)
          }
        } else {
          volatileCount += 1
          for sink in composedSinks {
            await sink.didReceiveVolatile(text, wallclockOffsetMs: offsetMs)
          }
        }
        if inline {
          if result.isFinal {
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
      return (volatileCount, finalCount)
    }

    // Drain PCM buffers into the optional WAV sidecar concurrently with
    // analyzer consumption.
    let pcmTask = Task {
      for await ref in sysSource.pcmBuffers {
        if let file = audioFileBox.file {
          try? file.write(from: ref.buffer)
        }
      }
    }

    do {
      try await sysSource.start()
    } catch let e as SysAudioSourceError {
      FileHandle.standardError.write(Data("[sysaudio] error: \(e.description)\n".utf8))
      throw ExitCode(2)
    }
    FileHandle.standardError.write(Data("[sysaudio] capture started; play audio in any app. Ctrl-C to stop.\n".utf8))

    try await analyzer.start(inputSequence: sysSource.analyzerInputs)

    if seconds > 0 {
      FileHandle.standardError.write(Data("[sysaudio] will auto-stop after \(seconds)s\n".utf8))
      try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    } else {
      await SignalHandler.waitForTermination()
    }

    FileHandle.standardError.write(Data("\n[sysaudio] stopping...\n".utf8))
    sysSource.stop()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let (volatileCount, finalCount) = try await consumeTask.value
    _ = await pcmTask.value
    for sink in composedSinks {
      await sink.finish()
    }

    FileHandle.standardError.write(Data(
      "[sysaudio] done. volatile=\(volatileCount) final=\(finalCount)\n".utf8
    ))
  }
}

/// Sendable wrapper so the pcm-drain task can hold a reference to an
/// AVAudioFile without a Sendable warning.
private final class SysAudioFileBox: @unchecked Sendable {
  let file: AVAudioFile?
  init(file: AVAudioFile?) { self.file = file }
}
