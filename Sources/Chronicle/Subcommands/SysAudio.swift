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

  @Option(name: .long, help: "Locale, e.g. en-US. Use 'auto' for the operator's default safe set, 'auto:en-US,pt-BR,...' for an explicit candidate list, or 'auto:*' to allow any SpeechTranscriber-supported locale. ADR-0003 governs auto-detect policy; FR-6 wiring lands incrementally.")
  var locale: String?

  @Option(name: [.long, .customShort("o")], help: "Append source-aware volatile + final events to this JSONL trace path.")
  var output: String?

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

  @Flag(name: .long, help: "Live speaker diarization via FluidAudio Sortformer. Attaches speakerId to JSONL trace events and prefixes finals with the speaker label.")
  var diarize: Bool = false

  @Option(name: .long, help: "Locale auto-detect hysteresis: minimum consecutive finals at the same candidate before switching (ADR-0003 default: 3).")
  var localeMinFinals: Int = LocaleHysteresisConfig.default.minFinals

  @Option(name: .long, help: "Locale auto-detect hysteresis: minimum NLLanguageRecognizer confidence required to count a final toward a switch (ADR-0003 default: 0.70).")
  var localeConfidence: Double = LocaleHysteresisConfig.default.confidence

  @Option(name: .long, help: "Locale auto-detect hysteresis: cooldown in seconds after a switch before another switch may apply (ADR-0003 default: 30 s).")
  var localeCooldownSec: Double = LocaleHysteresisConfig.default.cooldownSeconds

  @Option(name: .long, help: "Locale auto-detect hysteresis: minimum total characters at the new candidate across the consecutive-final run (ADR-0003 default: 30).")
  var localeMinChars: Int = LocaleHysteresisConfig.default.minChars

  func run() async throws {
    guard #available(macOS 26.0, *) else {
      throw ValidationError("Requires macOS 26.0+.")
    }

    let rawLocale = locale ?? Locale.current.identifier
    let localeSpec = try LocaleSpec.parse(rawLocale)
    let requestedLocale = Locale(identifier: localeSpec.initialLocaleIdentifier(default: Locale.current.identifier))
    let txEngine = try await TranscriptionEngine.make(
      locale: requestedLocale,
      preset: .progressiveTranscription,
      tag: "sysaudio"
    )
    let supported = txEngine.locale
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
    FileHandle.standardError.write(Data(
      "[sysaudio] captureSource=CoreAudioTapSource source=system-output mic=not-opened sidecarFormat=analyzer-pcm\n".utf8
    ))

    // Optional raw-audio sidecar (writes the analyzer-format buffer; not
    // the CoreAudio tap native format).
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
    let traceSink: JSONLTraceSink?
    if let output = self.output {
      let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[INFO] [sysaudio] appending JSONL trace to \(url.path)\n".utf8))
      let sink = try JSONLTraceSink(
        url: url,
        source: "sysaudio",
        sourceKind: .systemOutput,
        locale: supported.identifier,
        preset: TranscriptionEngine.presetName(.progressiveTranscription),
        recordTranscriptionLatency: true
      )
      traceSink = sink
      sinks.append(sink)
    } else {
      traceSink = nil
    }
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
    let resultClock = LiveResultClock()

    var localeResolver = localeSpec.makeResolver(
      currentLocale: supported.bcp47Identifier,
      hysteresis: LocaleHysteresisConfig(
        minFinals: localeMinFinals,
        confidence: localeConfidence,
        cooldownSeconds: localeCooldownSec,
        minChars: localeMinChars
      )
    )
    if let resolver = localeResolver {
      FileHandle.standardError.write(Data(
        "[sysaudio.locale] auto-detect enabled current=\(resolver.currentLocale) candidates=\(resolver.candidateSet.isEmpty ? "any" : resolver.candidateSet.joined(separator: ",")) minFinals=\(resolver.hysteresis.minFinals) confidence=\(resolver.hysteresis.confidence) cooldownSec=\(resolver.hysteresis.cooldownSeconds) minChars=\(resolver.hysteresis.minChars)\n".utf8
      ))
    }

    // Optional live diarizer. When enabled, route PCM buffers through a
    // multicast so the sidecar consumer and the diarizer each get an
    // independent stream without re-reading the source.
    let diarizer: SortformerStreamingDiarizer? = diarize
      ? SortformerStreamingDiarizer(logTag: "sysaudio.diarize")
      : nil
    let pcmMulticast: BufferMulticast<PCMBufferRef>?
    let sidecarStream: AsyncStream<PCMBufferRef>
    let diarizerStream: AsyncStream<PCMBufferRef>?
    if let _ = diarizer {
      let mc = BufferMulticast<PCMBufferRef>()
      pcmMulticast = mc
      sidecarStream = mc.subscribe()
      diarizerStream = mc.subscribe()
      FileHandle.standardError.write(Data("[sysaudio] diarization enabled (Sortformer streaming)\n".utf8))
    } else {
      pcmMulticast = nil
      sidecarStream = sysSource.pcmBuffers
      diarizerStream = nil
    }

    let diarizerPrepareTask: Task<Void, Never>? = diarizer.map { d in
      Task {
        do {
          try await d.prepare()
        } catch {
          FileHandle.standardError.write(Data(
            "[sysaudio.diarize] prewarm failed: \(error)\n".utf8
          ))
        }
      }
    }

    let consumeTask = Task {
      var lastVolatileLineLength = 0
      var volatileCount = 0
      var finalCount = 0
      var latencyMonitor = TranscriptionLatencyMonitor(logTag: "sysaudio")
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let offsetMs = resultClock.millisecondsSinceStart()
        let wallclock = Date()
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(result.range.end)
        let audioRange = start.isFinite && end.isFinite
          ? TraceAudioRange(startSeconds: start, endSeconds: end)
          : nil
        let speakerId: String?
        if let diarizer, let audioRange {
          speakerId = await diarizer.speakerId(forRange: audioRange)
        } else {
          speakerId = nil
        }
        if let snapshot = latencyMonitor.record(
          isFinal: result.isFinal,
          wallclockOffsetMs: offsetMs,
          audioRange: audioRange,
          speakerId: speakerId
        ) {
          TranscriptionLatencyMonitor.emit(logTag: "sysaudio", snapshot: snapshot)
        }
        if result.isFinal, localeResolver != nil {
          let decision = localeResolver!.consider(final: text)
          await LocaleResolverWiring.report(
            logTag: "sysaudio",
            decision: decision,
            traceSink: traceSink,
            wallclockOffsetMs: offsetMs,
            wallclock: wallclock
          )
        }
        for sink in composedSinks {
          await sink.didReceiveResult(
            text,
            isFinal: result.isFinal,
            wallclockOffsetMs: offsetMs,
            wallclock: wallclock,
            audioRange: audioRange,
            speakerId: speakerId
          )
        }
        if let traceSink {
          let stats = await traceSink.stats()
          if stats.droppedEvents > 0 {
            throw JSONLTraceSinkFailure(stats: stats)
          }
        }
        if result.isFinal {
          finalCount += 1
        } else {
          volatileCount += 1
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
      if let snapshot = latencyMonitor.finalSnapshot() {
        TranscriptionLatencyMonitor.emit(logTag: "sysaudio", snapshot: snapshot)
      }
      return (volatileCount, finalCount)
    }

    // Drain PCM buffers into the optional audio sidecar (ALAC / WAV /
    // Opus / rolling PCM scratch) concurrently with analyzer consumption.
    let pcmTask = Task {
      for await ref in sidecarStream {
        if let sink = audioSink {
          await sink.append(ref.buffer)
        }
      }
    }

    // When diarization is enabled, fan the same PCM stream from the source
    // into the multicast and feed the diarizer subscription.
    let multicastFanTask: Task<Void, Never>? = pcmMulticast.map { mc in
      Task {
        for await ref in sysSource.pcmBuffers {
          mc.yield(ref)
        }
        mc.finish()
      }
    }
    let diarizerTask: Task<Void, Never>? = (diarizer.flatMap { d in
      diarizerStream.map { stream in
        Task {
          for await ref in stream {
            do {
              try await d.ingest(ref)
            } catch {
              FileHandle.standardError.write(Data(
                "[sysaudio.diarize] ingest failed: \(error)\n".utf8
              ))
            }
          }
        }
      }
    })

    do {
      try await sysSource.start()
      FileHandle.standardError.write(Data("[sysaudio] capture started; play audio in any app. Ctrl-C to stop.\n".utf8))

      resultClock.markStarted()
      try await analyzer.start(inputSequence: sysSource.analyzerInputs)
    } catch let e as CoreAudioTapSourceError {
      diarizerPrepareTask?.cancel()
      await diarizerPrepareTask?.value
      FileHandle.standardError.write(Data("[sysaudio] error: \(e.description)\n".utf8))
      throw ExitCode(2)
    } catch {
      diarizerPrepareTask?.cancel()
      await diarizerPrepareTask?.value
      throw error
    }

    if seconds > 0 {
      FileHandle.standardError.write(Data("[sysaudio] will auto-stop after \(seconds)s\n".utf8))
      try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    } else {
      await SignalHandler.waitForTermination()
    }

    FileHandle.standardError.write(Data("\n[sysaudio] stopping...\n".utf8))
    sysSource.stop()
    // Bound the analyzer finalize. When the analyzer received no real
    // input (e.g. audio TCC denied or silent tap startup) this can
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
    let counts: (volatile: Int, final: Int)
    do {
      counts = try await consumeTask.value
    } catch {
      _ = await pcmTask.value
      await multicastFanTask?.value
      await diarizerTask?.value
      await diarizerPrepareTask?.value
      if let diarizer { await diarizer.finish() }
      if let audioSink {
        await audioSink.finish()
      }
      for sink in composedSinks {
        await sink.finish()
      }
      if let traceSink {
        let stats = await traceSink.stats()
        FileHandle.standardError.write(Data(
          "[sysaudio] trace.written=\(stats.writtenEvents) trace.dropped=\(stats.droppedEvents)\n".utf8
        ))
      }
      throw error
    }
    _ = await pcmTask.value
    await multicastFanTask?.value
    await diarizerTask?.value
    await diarizerPrepareTask?.value
    if let diarizer { await diarizer.finish() }
    if let audioSink {
      await audioSink.finish()
    }
    for sink in composedSinks {
      await sink.finish()
    }

    FileHandle.standardError.write(Data(
      "[sysaudio] done. volatile=\(counts.volatile) final=\(counts.final)\n".utf8
    ))
    if let traceSink {
      let stats = await traceSink.stats()
      FileHandle.standardError.write(Data(
        "[sysaudio] trace.written=\(stats.writtenEvents) trace.dropped=\(stats.droppedEvents)\n".utf8
      ))
      if stats.droppedEvents > 0 {
        throw ExitCode(3)
      }
    }
  }
}
