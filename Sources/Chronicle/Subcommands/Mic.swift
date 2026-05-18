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
    FileHandle.standardError.write(Data(
      "[mic] captureSource=MicAudioSource source=microphone systemOutput=not-opened sidecarFormat=analyzer-pcm\n".utf8
    ))

    // Optional raw-audio sidecar.
    let audioSink: AudioSidecarSink? = try makeAudioSidecarSink(
      path: saveAudio,
      analyzerFormat: analyzerFormat,
      audioFormat: audioFormat,
      opusBitRate: opusBitRate,
      scratchTtl: scratchTtl,
      scratchRotate: scratchRotate,
      rotateAudio: rotateAudio
    )

    let inline = self.inline

    // Optional live diarizer. When enabled, route PCM buffers through a
    // multicast so the sidecar consumer and the diarizer each get an
    // independent stream without re-reading the source.
    let diarizer: SortformerStreamingDiarizer? = diarize
      ? SortformerStreamingDiarizer(logTag: "mic.diarize")
      : nil
    let pcmMulticast: BufferMulticast<PCMBufferRef>?
    let sidecarStream: AsyncStream<PCMBufferRef>
    let diarizerStream: AsyncStream<PCMBufferRef>?
    if let _ = diarizer {
      let mc = BufferMulticast<PCMBufferRef>()
      pcmMulticast = mc
      sidecarStream = mc.subscribe()
      diarizerStream = mc.subscribe()
      FileHandle.standardError.write(Data("[mic] diarization enabled (Sortformer streaming)\n".utf8))
    } else {
      pcmMulticast = nil
      sidecarStream = micSource.pcmBuffers
      diarizerStream = nil
    }

    // Compose sidecar sinks.
    var sinks: [TranscriptionSink] = []
    let traceSink: JSONLTraceSink?
    if let output = self.output {
      let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[INFO] [mic] appending JSONL trace to \(url.path)\n".utf8))
      let sink = try JSONLTraceSink(
        url: url,
        source: "mic",
        sourceKind: .microphone,
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
      FileHandle.standardError.write(Data("[mic] live transcript file: \(url.path)\n".utf8))
      sinks.append(LiveFileSink(url: url))
    }
    if let path = self.append {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[mic] appending finals to \(url.path)\n".utf8))
      sinks.append(FinalsAppendSink(url: url))
    }
    let composedSinks = sinks

    let resultClock = LiveResultClock()

    let diarizerPrepareTask: Task<Void, Never>? = diarizer.map { d in
      Task {
        do {
          try await d.prepare()
        } catch {
          FileHandle.standardError.write(Data(
            "[mic.diarize] prewarm failed: \(error)\n".utf8
          ))
        }
      }
    }

    let consumeTask = Task {
      var lastVolatileLineLength = 0
      var volatileCount = 0
      var finalCount = 0
      var latencyMonitor = TranscriptionLatencyMonitor(logTag: "mic")
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
          TranscriptionLatencyMonitor.emit(logTag: "mic", snapshot: snapshot)
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

    // When diarization is enabled, fan the same PCM stream from the source
    // into the multicast and feed the diarizer subscription.
    let multicastFanTask: Task<Void, Never>? = pcmMulticast.map { mc in
      Task {
        for await ref in micSource.pcmBuffers {
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
                "[mic.diarize] ingest failed: \(error)\n".utf8
              ))
            }
          }
        }
      }
    })

    do {
      try await micSource.start()
      FileHandle.standardError.write(Data("[mic] engine started; speak into the mic. Ctrl-C to stop.\n".utf8))

      // Kick off the analyzer over our input sequence.
      resultClock.markStarted()
      try await analyzer.start(inputSequence: micSource.analyzerInputs)
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
      if let traceSink {
        let stats = await traceSink.stats()
        FileHandle.standardError.write(Data(
          "[mic] trace.written=\(stats.writtenEvents) trace.dropped=\(stats.droppedEvents)\n".utf8
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
      "[mic] done. volatile=\(counts.volatile) final=\(counts.final)\n".utf8
    ))
    if let traceSink {
      let stats = await traceSink.stats()
      FileHandle.standardError.write(Data(
        "[mic] trace.written=\(stats.writtenEvents) trace.dropped=\(stats.droppedEvents)\n".utf8
      ))
      if stats.droppedEvents > 0 {
        throw ExitCode(3)
      }
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
    let primary = try maybeRotating(label: "AVAudioFileALACSink") { segmentURL in
      FileHandle.standardError.write(Data("[audio] AVAudioFileALACSink -> \(segmentURL.path) (source=\(analyzerFormat))\n".utf8))
      return try AVAudioFileALACSink(url: segmentURL, sourceFormat: analyzerFormat)
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
