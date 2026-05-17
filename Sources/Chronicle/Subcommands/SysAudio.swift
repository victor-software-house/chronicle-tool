import ArgumentParser
import AVFoundation
import Foundation
import Speech

/// Live system-audio transcription via CoreAudio process tap +
/// `SpeechAnalyzer` progressive preset. Captures every app's audio output
/// (system mix) and produces the same sidecar artefacts as `chronicle mic`
/// (live snapshot + timestamped finals).
///
/// Requires System Audio Recording permission (`NSAudioCaptureUsageDescription`
/// is set in Info.plist; macOS will prompt on first tap creation).
struct SysAudio: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sysaudio",
    abstract: "Live system-audio transcription via CoreAudio process tap + SpeechAnalyzer (on-device, requires System Audio Recording permission)."
  )

  @Option(name: .long, help: "Locale, e.g. en-US. Locale auto-detect (ADR-0003) lands with FR-6/P4.")
  var locale: String?

  @Option(name: .long, help: "Stop after this many seconds (0 = run until SIGINT/SIGTERM).")
  var seconds: Int = 0

  @Option(name: .long, help: "Append each finalized segment (with timestamp) to this file.")
  var append: String?

  @Option(name: .long, help: "Rewrite this file on every event with the rolling live transcript.")
  var live: String?

  @Option(name: .long, help: "Also save the raw system-audio sidecar to this path. Extension depends on --audio-format.")
  var saveAudio: String?

  @Option(name: .long, help: "Audio sidecar codec: 'alac' (default ALAC in CAF), 'wav' (lossless debug), 'pcm' (rolling raw-PCM scratch), or 'opus' (opt-in lossy CAF).")
  var audioFormat: String = "alac"

  @Option(name: .long, help: "Opus target bitrate in bps (default 24000). Only meaningful when --audio-format=opus.")
  var opusBitRate: Int = OpusCAFSink.defaultBitRate

  @Option(name: .long, help: "PCM scratch TTL in seconds (default 300). Used by default ALAC scratch and --audio-format=pcm.")
  var scratchTtl: Double = RollingPCMScratchSink.defaultTTLSeconds

  @Option(name: .long, help: "PCM scratch rotation interval in seconds (default 30). Used by default ALAC scratch and --audio-format=pcm.")
  var scratchRotate: Double = RollingPCMScratchSink.defaultRotateSeconds

  @Option(name: .long, help: "Audio sidecar rotation interval in seconds (default 60; 0 disables rotation). Applies to alac/wav/opus.")
  var rotateAudio: Double = 60.0

  @Flag(name: .long, help: "Include audio from this process. Default is to exclude (prevents feedback loops).")
  var includeSelfAudio: Bool = false

  @Flag(name: .long, help: "Render volatile updates inline (TTY repaint) instead of one line each.")
  var inline: Bool = false

  @Flag(name: .long, help: "Log CoreAudioTapSource buffer diagnostics every ~1.2s (buffer count + peak amplitude). Useful when audio appears silent.")
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

    let sysSource = CoreAudioTapSource(
      analyzerFormat: analyzerFormat,
      excludeCurrentProcessAudio: !includeSelfAudio,
      verbose: verbose
    )

    // Optional raw-audio sidecar (writes the analyzer-format buffer; not
    // the SCStream native format).
    let audioSink: AudioSidecarSink? = try makeAudioSidecarSink(
      path: saveAudio,
      analyzerFormat: analyzerFormat,
      audioFormat: audioFormat,
      opusBitRate: opusBitRate,
      scratchTtl: scratchTtl,
      scratchRotate: scratchRotate,
      rotateAudio: rotateAudio
    )

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

    // Drain PCM buffers into the optional audio sidecar (ALAC / WAV /
    // Opus / rolling PCM scratch) concurrently with analyzer consumption.
    let pcmTask = Task {
      for await ref in sysSource.pcmBuffers {
        if let sink = audioSink {
          await sink.append(ref.buffer)
        }
      }
    }

    do {
      try await sysSource.start()
    } catch let e as CoreAudioTapSourceError {
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
    // Bound the analyzer finalize. When the analyzer received no real
    // input (e.g. audio TCC denied + garbage SCStream buffers) this can
    // otherwise hang indefinitely. On timeout fall back to a hard
    // cancel-and-finish (also bounded).
    do {
      try await withTimeout(seconds: 5.0, label: "analyzer.finalize") {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      }
    } catch is TimeoutError {
      FileHandle.standardError.write(Data(
        "[sysaudio] analyzer.finalize timed out; falling back to cancelAndFinishNow\n".utf8
      ))
      try? await withTimeout(seconds: 2.0, label: "analyzer.cancelAndFinishNow") {
        try await analyzer.cancelAndFinishNow()
      }
    }
    let (volatileCount, finalCount) = try await consumeTask.value
    _ = await pcmTask.value
    if let audioSink {
      await audioSink.finish()
    }
    for sink in composedSinks {
      await sink.finish()
    }

    FileHandle.standardError.write(Data(
      "[sysaudio] done. volatile=\(volatileCount) final=\(finalCount)\n".utf8
    ))
  }
}
