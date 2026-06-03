import ChronicleCore
import ArgumentParser
import ChronicleCore
import AVFoundation
import ChronicleCore
import Foundation
import ChronicleCore
import Speech

#if canImport(Darwin)
import ChronicleCore
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

  @Option(name: .long, help: "Locale, e.g. en-US. Use 'auto' for the operator's default safe set, 'auto:en-US,pt-BR,...' for an explicit candidate list, or 'auto:*' to allow any SpeechTranscriber-supported locale.")
  var locale: String?

  @Option(name: [.long, .customShort("o")], help: "Append source-aware volatile + final events to this JSONL trace path.")
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

    let captureConfiguration = LiveCaptureConfiguration.direct(
      source: .mic,
      locale: locale,
      output: output,
      append: append,
      live: live,
      saveAudio: saveAudio,
      audioFormat: audioFormat,
      diarize: diarize,
      rotateAudio: rotateAudio
    )

    let rawLocale = captureConfiguration.locale ?? Locale.current.identifier
    let localeSpec = try LocaleSpec.parse(rawLocale)
    let requestedLocale = Locale(identifier: localeSpec.initialLocaleIdentifier(default: Locale.current.identifier))
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
    FileHandle.standardError.write(Data(
      "[mic] captureSource=MicAudioSource source=microphone systemOutput=not-opened sidecarFormat=analyzer-pcm\n".utf8
    ))

    // Optional raw-audio sidecar.
    let audioSink: AudioSidecarSink? = try makeAudioSidecarSink(
      path: captureConfiguration.audioPath,
      analyzerFormat: analyzerFormat,
      audioFormat: captureConfiguration.audioFormat,
      opusBitRate: opusBitRate,
      scratchTtl: scratchTtl,
      scratchRotate: scratchRotate,
      rotateAudio: rotateAudio
    )

    let inline = self.inline

    // Optional live diarizer. When enabled, route PCM buffers through a
    // multicast so the sidecar consumer and the diarizer each get an
    // independent stream without re-reading the source.
    let diarizer: SortformerStreamingDiarizer? = captureConfiguration.diarizationEnabled
      ? SortformerStreamingDiarizer(logTag: "mic.diarize")
      : nil
    // Use a multicast when diarization or locale auto-detect needs a
    // parallel PCM subscriber. The audio probe (ADR-0006) needs its own
    // subscription so it doesn't consume the main pcmBuffers stream.
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
        FileHandle.standardError.write(Data("[mic] diarization enabled (Sortformer streaming)\n".utf8))
      }
    } else {
      pcmMulticast = nil
      sidecarStream = micSource.pcmBuffers
      diarizerStream = nil
      probeStream = nil
    }

    // Resolve output paths: explicit CLI overrides take precedence,
    // otherwise auto-generate a timestamped session directory.
    let paths = try SessionOutputPaths.resolve(
      source: "mic",
      outputOverride: captureConfiguration.tracePath,
      appendOverride: captureConfiguration.finalsPath,
      liveOverride: captureConfiguration.livePath
    )
    FileHandle.standardError.write(Data("[mic] session dir: \(paths.sessionDir.path)\n".utf8))

    // Compose sidecar sinks — always on.
    var sinks: [TranscriptionSink] = []
    FileHandle.standardError.write(Data("[INFO] [mic] appending JSONL trace to \(paths.trace.path)\n".utf8))
    let traceSink = try JSONLTraceSink(
      url: paths.trace,
      source: "mic",
      sourceKind: .microphone,
      locale: supported.identifier,
      preset: TranscriptionEngine.presetName(.progressiveTranscription),
      recordTranscriptionLatency: true
    )
    sinks.append(traceSink)
    FileHandle.standardError.write(Data("[mic] live transcript: \(paths.live.path)\n".utf8))
    sinks.append(LiveFileSink(url: paths.live))
    FileHandle.standardError.write(Data("[mic] appending finals to \(paths.finals.path)\n".utf8))
    sinks.append(FinalsAppendSink(url: paths.finals))
    let composedSinks = sinks

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
        "[mic.locale] auto-detect enabled current=\(resolver.currentLocale) candidates=\(resolver.candidateSet.isEmpty ? "any" : resolver.candidateSet.joined(separator: ",")) minFinals=\(resolver.hysteresis.minFinals) confidence=\(resolver.hysteresis.confidence) cooldownSec=\(resolver.hysteresis.cooldownSeconds) minChars=\(resolver.hysteresis.minChars)\n".utf8
      ))
    }

    if let diarizer {
      FileHandle.standardError.write(Data("[mic.diarize] prewarming in background; transcript starts immediately and speaker labels appear when ready\n".utf8))
    }

    // --- Audio language detection (ADR-0006) ---
    // Runs BEFORE analyzer and diarizer so WhisperKit gets exclusive ANE.
    try await micSource.start()
    FileHandle.standardError.write(Data("[mic] engine started; speak into the mic. Ctrl-C to stop.\n".utf8))

    // Start multicast fan so all subscribers receive buffers.
    let multicastFanTask: Task<Void, Never>? = pcmMulticast.map { mc in
      Task {
        for await ref in micSource.pcmBuffers {
          mc.yield(ref)
        }
        mc.finish()
      }
    }

    // Audio language detection (ADR-0006): runs CONCURRENTLY with
    // transcription. Uses tiny model on CPU-only — no ANE contention
    // with SpeechTranscriber or Sortformer. ~570ms per detection.
    // Retries up to 3x if confidence is low. Hot-swaps locale on success.
    // Swap channel: probe pushes new transcriber, consume loop restarts.
    let (swapStream, swapContinuation) = AsyncStream.makeStream(of: SpeechTranscriber.self)

    let audioProbeTask: Task<Void, Never>? = probeStream.map { stream in
      let fmt = analyzerFormat
      let candidates = localeResolver?.candidateSet ?? []
      let currentBcp47 = supported.bcp47Identifier
      return Task {
        do {
          let audioDetector = AudioLanguageDetector(verbose: true)
          try await audioDetector.load()
          guard let detection = try await AudioLanguageProbe.detect(
            stream: stream,
            sampleRate: fmt.sampleRate,
            detector: audioDetector,
            logTag: "mic"
          ) else { return }
          let detectedBcp47 = LocaleResolverWiring.resolveFullLocale(
            baseLanguage: detection.language,
            currentLocale: currentBcp47,
            candidates: candidates
          )
          if detectedBcp47 != currentBcp47 {
            FileHandle.standardError.write(Data(
              "[mic.locale] audio detected=\(detection.language) (\(String(format: "%.3f", detection.confidence))); switching from \(currentBcp47) to \(detectedBcp47)\n".utf8
            ))
            if let newTranscriber = await LocaleResolverWiring.hotSwapLocale(
              logTag: "mic",
              analyzer: analyzer,
              to: detectedBcp47,
              preset: .progressiveTranscription
            ) {
              swapContinuation.yield(newTranscriber)
            }
          } else {
            FileHandle.standardError.write(Data(
              "[mic.locale] audio confirmed=\(detection.language); staying at \(currentBcp47)\n".utf8
            ))
          }
        } catch {
          FileHandle.standardError.write(Data(
            "[mic.locale] audio detection failed: \(error)\n".utf8
          ))
        }
      }
    }
    _ = audioProbeTask

    let diarizerPrepareTask: Task<Void, Never>? = diarizer.map { d in
      Task {
        do {
          try await d.prepare()
          FileHandle.standardError.write(Data("[mic.diarize] prewarm complete; live speaker labels available for covered audio ranges\n".utf8))
        } catch {
          FileHandle.standardError.write(Data(
            "[mic.diarize] prewarm failed: \(error)\n".utf8
          ))
        }
      }
    }

    nonisolated(unsafe) var resolverSnapshot = localeResolver
    let consumeTask = Task {
      var lastVolatileLineLength = 0
      var volatileCount = 0
      var finalCount = 0
      var latencyMonitor = TranscriptionLatencyMonitor(logTag: "mic")
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
            TranscriptionLatencyMonitor.emit(logTag: "mic", snapshot: snapshot)
          }
          if result.isFinal, resolverSnapshot != nil {
            let decision = resolverSnapshot!.consider(final: text)
            await LocaleResolverWiring.report(
              logTag: "mic",
              decision: decision,
              traceSink: traceSink,
              wallclockOffsetMs: offsetMs,
              wallclock: wallclock
            )
            if case let .switchTo(to, _, _, _) = decision {
              if let _ = await LocaleResolverWiring.hotSwapLocale(
                logTag: "mic",
                analyzer: analyzer,
                to: to,
                preset: .progressiveTranscription
              ) {
                // Text-based mid-session swap; results continue from analyzer
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
        // Inner for-await ended. Check for a transcriber swap.
        if let newT = await swapIter.next() {
          currentTranscriber = newT
          FileHandle.standardError.write(Data("[mic] transcriber swapped; restarting results loop\n".utf8))
          continue
        }
        break
      }
      if let snapshot = latencyMonitor.finalSnapshot() {
        TranscriptionLatencyMonitor.emit(logTag: "mic", snapshot: snapshot)
      }
      return (volatileCount, finalCount)
    }

    // Drain PCM buffers into the optional audio sidecar (ALAC / WAV / Opus /
    // rolling PCM scratch) concurrently with analyzer consumption.
    // MicAudioSource already converts to analyzerFormat.
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
                "[mic.diarize] ingest failed: \(error)\n".utf8
              ))
            }
          }
        }
      }
    })

    do {
      resultClock.markStarted()
      try await analyzer.start(inputSequence: micSource.analyzerInputs)
    } catch let e as MicAudioSourceError {
      diarizerPrepareTask?.cancel()
      await diarizerPrepareTask?.value
      FileHandle.standardError.write(Data("[mic] error: \(e.description)\n".utf8))
      throw ExitCode(2)
    } catch {
      diarizerPrepareTask?.cancel()
      await diarizerPrepareTask?.value
      throw error
    }

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
        "[mic] trace.written=\(errStats.writtenEvents) trace.dropped=\(errStats.droppedEvents)\n".utf8
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
      "[mic] done. volatile=\(counts.volatile) final=\(counts.final)\n".utf8
    ))
    let finalStats = await traceSink.stats()
    FileHandle.standardError.write(Data(
      "[mic] trace.written=\(finalStats.writtenEvents) trace.dropped=\(finalStats.droppedEvents)\n".utf8
    ))
    if finalStats.droppedEvents > 0 {
      throw ExitCode(3)
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
  scratchRotate: Double = RollingPCMScratchSink.defaultRotateSeconds,
  rotateAudio: Double = 60.0
) throws -> AudioSidecarSink? {
  guard let path else { return nil }
  let expanded = (path as NSString).expandingTildeInPath
  let url = URL(fileURLWithPath: expanded)
  let kind = (audioFormat ?? "alac").lowercased()

  func scratchBase(for sidecarURL: URL) -> URL {
    sidecarURL
      .deletingLastPathComponent()
      .appendingPathComponent("scratch", isDirectory: true)
      .appendingPathComponent(sidecarURL.deletingPathExtension().lastPathComponent, isDirectory: true)
  }

  func maybeRotating(
    label: String,
    factory: @escaping @Sendable (URL) throws -> AudioSidecarSink
  ) throws -> AudioSidecarSink {
    if rotateAudio > 0 {
      FileHandle.standardError.write(Data("[audio] \(label) rotating every \(rotateAudio)s from \(url.path)\n".utf8))
      return try RotatingAudioSidecarSink(
        baseURL: url,
        rotateInterval: rotateAudio,
        sourceFormat: analyzerFormat,
        factory: factory
      )
    }
    return try factory(url)
  }

  switch kind {
  case "alac":
    let primary = try maybeRotating(label: "ExtAudioFileALACSink") { segmentURL in
      FileHandle.standardError.write(Data("[audio] ExtAudioFileALACSink -> \(segmentURL.path) (source=\(analyzerFormat))\n".utf8))
      return try ExtAudioFileALACSink(url: segmentURL, sourceFormat: analyzerFormat)
    }
    let scratchURL = scratchBase(for: url)
    FileHandle.standardError.write(Data("[audio] RollingPCMScratchSink -> \(scratchURL.path)/ (ttl=\(scratchTtl)s rotate=\(scratchRotate)s)\n".utf8))
    let scratch = try RollingPCMScratchSink(
      base: scratchURL,
      sourceFormat: analyzerFormat,
      ttl: scratchTtl,
      rotateInterval: scratchRotate
    )
    return CompositeAudioSidecarSink([primary, scratch])
  case "opus":
    return try maybeRotating(label: "OpusCAFSink") { segmentURL in
      FileHandle.standardError.write(Data("[audio] OpusCAFSink -> \(segmentURL.path) (\(opusBitRate) bps, source=\(analyzerFormat))\n".utf8))
      return try OpusCAFSink(url: segmentURL, sourceFormat: analyzerFormat, bitRate: opusBitRate)
    }
  case "wav":
    return try maybeRotating(label: "WAVSidecarSink") { segmentURL in
      FileHandle.standardError.write(Data("[audio] WAVSidecarSink -> \(segmentURL.path) (\(analyzerFormat))\n".utf8))
      return try WAVSidecarSink(url: segmentURL, sourceFormat: analyzerFormat)
    }
  case "pcm":
    FileHandle.standardError.write(Data("[audio] RollingPCMScratchSink -> \(url.path)/ (ttl=\(scratchTtl)s rotate=\(scratchRotate)s)\n".utf8))
    return try RollingPCMScratchSink(
      base: url,
      sourceFormat: analyzerFormat,
      ttl: scratchTtl,
      rotateInterval: scratchRotate
    )
  default:
    throw ValidationError("--audio-format must be one of {alac, opus, wav, pcm}; got '\(kind)'")
  }
}
