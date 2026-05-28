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

  @Flag(name: .long, help: "Suppress volatile/final transcript lines on stdout. Sidecar files are still written.")
  var quiet: Bool = false

  @Flag(name: .long, help: "Log CoreAudioTapSource state transitions and periodic peak summaries. Useful when audio appears silent.")
  var verbose: Bool = false

  @Flag(name: .long, help: "Log per-buffer tap diagnostics (very noisy). Use only when debugging CoreAudio capture internals.")
  var debugTap: Bool = false

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

    // Best-effort TCC grant probe via private SPI. Advisory only:
    // - The SPI runs inside the responsible-parent context (cmux/Terminal),
    //   so an undetermined result for a child CLI does not mean "no grant".
    // - Per ADR-0007, the real Tahoe 26.5 failure mode is the coreaudiod
    //   zero-buffer regression — not TCC. Refusing to start here would be
    //   strictly worse than letting the tap run and surfacing the regression.
    // Log the probe result and continue.
    switch TCCPreflight.systemAudioRecording() {
    case .granted:
      break
    case .denied:
      FileHandle.standardError.write(Data(
        "[sysaudio.tcc] preflight reports DENIED, but this private check is advisory only. Continuing; runtime PCM peak and transcript output determine capture health. \(TCCPreflight.systemAudioRecordingRemediation)\n".utf8
      ))
    case .undetermined:
      FileHandle.standardError.write(Data(
        "[sysaudio.tcc] preflight is undetermined (responsible-parent context). Continuing; runtime PCM peak and transcript output determine capture health.\n".utf8
      ))
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
      verbose: verbose || debugTap,
      debugBuffers: debugTap
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

    // Resolve output paths: explicit CLI overrides take precedence,
    // otherwise auto-generate a timestamped session directory.
    let paths = try SessionOutputPaths.resolve(
      source: "sysaudio",
      outputOverride: self.output,
      appendOverride: self.append,
      liveOverride: self.live
    )
    FileHandle.standardError.write(Data("[sysaudio] session dir: \(paths.sessionDir.path)\n".utf8))

    // Compose sidecar sinks — always on.
    var sinks: [TranscriptionSink] = []
    FileHandle.standardError.write(Data("[INFO] [sysaudio] appending JSONL trace to \(paths.trace.path)\n".utf8))
    let traceSink = try JSONLTraceSink(
      url: paths.trace,
      source: "sysaudio",
      sourceKind: .systemOutput,
      locale: supported.identifier,
      preset: TranscriptionEngine.presetName(.progressiveTranscription),
      recordTranscriptionLatency: true
    )
    sinks.append(traceSink)
    FileHandle.standardError.write(Data("[sysaudio] live transcript: \(paths.live.path)\n".utf8))
    sinks.append(LiveFileSink(url: paths.live))
    FileHandle.standardError.write(Data("[sysaudio] appending finals to \(paths.finals.path)\n".utf8))
    sinks.append(FinalsAppendSink(url: paths.finals))
    let composedSinks = sinks

    let inline = self.inline
    let quiet = self.quiet
    let resultClock = LiveResultClock()

    var localeResolver = try localeSpec.makeResolver(
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
    let needsMulticast = diarizer != nil || !localeSpec.isPin
    let pcmMulticast: BufferMulticast<PCMBufferRef>?
    let sidecarStream: AsyncStream<PCMBufferRef>
    let diarizerStream: AsyncStream<PCMBufferRef>?
    let probeStream: AsyncStream<PCMBufferRef>?
    if needsMulticast {
      let mc = BufferMulticast<PCMBufferRef>()
      pcmMulticast = mc
      sidecarStream = mc.subscribe()
      diarizerStream = diarizer != nil ? mc.subscribe() : nil
      probeStream = !localeSpec.isPin ? mc.subscribe() : nil
      if diarizer != nil {
        FileHandle.standardError.write(Data("[sysaudio] diarization enabled (Sortformer streaming)\n".utf8))
      }
    } else {
      pcmMulticast = nil
      sidecarStream = sysSource.pcmBuffers
      diarizerStream = nil
      probeStream = nil
    }

    try await sysSource.start()
    FileHandle.standardError.write(Data("[sysaudio] capture started; play audio in any app. Ctrl-C to stop.\n".utf8))

    let multicastFanTask: Task<Void, Never>? = pcmMulticast.map { mc in
      Task {
        for await ref in sysSource.pcmBuffers {
          mc.yield(ref)
        }
        mc.finish()
      }
    }

    // Audio language detection (ADR-0006): concurrent, CPU-only, no ANE contention.
    let (swapStream, swapContinuation) = AsyncStream.makeStream(of: SpeechTranscriber.self)

    let audioProbeTask: Task<Void, Never>? = probeStream.map { stream in
      let fmt = analyzerFormat
      let candidates = localeResolver?.candidateSet ?? []
      let currentBcp47 = supported.bcp47Identifier
      return Task {
        do {
          let audioDetector = AudioLanguageDetector(verbose: verbose)
          try await audioDetector.load()
          guard let detection = try await AudioLanguageProbe.detect(
            stream: stream,
            sampleRate: fmt.sampleRate,
            detector: audioDetector,
            logTag: "sysaudio"
          ) else { return }
          let detectedBcp47 = LocaleResolverWiring.resolveFullLocale(
            baseLanguage: detection.language,
            currentLocale: currentBcp47,
            candidates: candidates
          )
          if detectedBcp47 != currentBcp47 {
            FileHandle.standardError.write(Data(
              "[sysaudio.locale] audio detected=\(detection.language) (\(String(format: "%.3f", detection.confidence))); switching from \(currentBcp47) to \(detectedBcp47)\n".utf8
            ))
            if let newTranscriber = await LocaleResolverWiring.hotSwapLocale(
              logTag: "sysaudio",
              analyzer: analyzer,
              to: detectedBcp47,
              preset: .progressiveTranscription
            ) {
              swapContinuation.yield(newTranscriber)
            }
          } else {
            FileHandle.standardError.write(Data(
              "[sysaudio.locale] audio confirmed=\(detection.language); staying at \(currentBcp47)\n".utf8
            ))
          }
        } catch {
          FileHandle.standardError.write(Data(
            "[sysaudio.locale] audio detection failed: \(error)\n".utf8
          ))
        }
      }
    }
    _ = audioProbeTask

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

    nonisolated(unsafe) var resolverSnapshot = localeResolver
    let consumeTask = Task {
      var lastVolatileLineLength = 0
      var volatileCount = 0
      var finalCount = 0
      var latencyMonitor = TranscriptionLatencyMonitor(logTag: "sysaudio")
      var currentTranscriber = transcriber
      var swapIter = swapStream.makeAsyncIterator()

      while !Task.isCancelled {
        for try await result in currentTranscriber.results {
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
          if result.isFinal, resolverSnapshot != nil {
            let decision = resolverSnapshot!.consider(final: text)
            await LocaleResolverWiring.report(
              logTag: "sysaudio",
              decision: decision,
              traceSink: traceSink,
              wallclockOffsetMs: offsetMs,
              wallclock: wallclock
            )
            if case let .switchTo(to, _, _, _) = decision {
              if let _ = await LocaleResolverWiring.hotSwapLocale(
                logTag: "sysaudio",
                analyzer: analyzer,
                to: to,
                preset: .progressiveTranscription
              ) {
                // Text-based mid-session swap
              }
            }
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
          let traceStats = await traceSink.stats()
          if traceStats.droppedEvents > 0 {
            throw JSONLTraceSinkFailure(stats: traceStats)
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
              if !quiet { print("\u{1b}[32mFINAL\u{1b}[0m \(text)") }
            } else if !quiet {
              let line = "\u{1b}[33mvolatile\u{1b}[0m \(text)"
              fputs("\r\(line)", stdout)
              fflush(stdout)
              lastVolatileLineLength = line.count
            }
          } else if !quiet {
            if result.isFinal {
              print("\u{1b}[32mFINAL\u{1b}[0m \(text)")
            } else {
              print("\u{1b}[33mvolatile\u{1b}[0m \(text)")
            }
          }
        }
        if let newT = await swapIter.next() {
          currentTranscriber = newT
          FileHandle.standardError.write(Data("[sysaudio] transcriber swapped; restarting results loop\n".utf8))
          continue
        }
        break
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

    // multicastFanTask already started above before the probe.
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
      let errStats = await traceSink.stats()
      FileHandle.standardError.write(Data(
        "[sysaudio] trace.written=\(errStats.writtenEvents) trace.dropped=\(errStats.droppedEvents)\n".utf8
      ))
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
    let finalStats = await traceSink.stats()
    FileHandle.standardError.write(Data(
      "[sysaudio] trace.written=\(finalStats.writtenEvents) trace.dropped=\(finalStats.droppedEvents)\n".utf8
    ))
    if finalStats.droppedEvents > 0 {
      throw ExitCode(3)
    }
  }
}
