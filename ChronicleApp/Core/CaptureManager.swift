import AVFoundation
import ChronicleCore
import Foundation
import Observation
import Speech

/// Bridges `ChronicleCore` capture lifecycle to SwiftUI `@Observable` state.
///
/// Orchestrates audio sources, transcription engine, sinks, and optional
/// diarization — the same pipeline that `Mic.swift` and `SysAudio.swift`
/// subcommands use — exposing reactive properties for the menu bar UI.
@Observable
@MainActor
final class CaptureManager {

  // MARK: - Observable state

  private(set) var state: CaptureState = .idle
  private(set) var sessionDuration: Duration?
  private(set) var sessionOutputURL: URL?

  var transcriptLines: [TranscriptLine] { transcriptSink.lines }
  var speakerCount: Int { transcriptSink.speakerCount }
  var activeSources: Set<CaptureSource> {
    if case .recording(let sources) = state { return sources }
    return []
  }

  // MARK: - Internal state

  private let settings: AppSettings
  private let transcriptSink = UITranscriptSink()
  private var captureTask: Task<Void, Never>?
  private var durationTask: Task<Void, Never>?
  private var durationStart: ContinuousClock.Instant?

  init(settings: AppSettings) {
    self.settings = settings
  }

  // MARK: - Public API

  func startCapture(sources: Set<CaptureSource>) async {
    guard case .idle = state else { return }
    state = .recording(sources: sources)
    sessionDuration = .zero
    durationStart = .now
    transcriptSink.clear()

    durationTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, let start = self.durationStart else { break }
        self.sessionDuration = .now - start
      }
    }

    // Each source gets its own independent pipeline (transcription engine,
    // sinks, optional diarizer) — preserving one-source-per-transcriber
    // isolation per AGENTS.md. Separate Tasks avoid Swift 6.2 TaskGroup
    // region-isolation checker limitations.
    var sourceTasks: [Task<Void, Never>] = []
    for source in sources {
      let s = source
      let task = Task { [weak self] in
        guard let self else { return }
        do {
          try await self.runSource(s)
        } catch is CancellationError {
          // normal stop
        } catch {
          self.state = .error(message: error.localizedDescription)
        }
      }
      sourceTasks.append(task)
    }
    captureTask = Task { [weak self] in
      for t in sourceTasks { await t.value }
      guard let self else { return }
      if case .recording = self.state { self.state = .idle }
    }
  }

  func stopCapture() async {
    guard case .recording = state else { return }
    captureTask?.cancel()
    await captureTask?.value
    captureTask = nil
    durationTask?.cancel()
    durationTask = nil
    state = .idle
  }

  func toggleDiarization() async {
    settings.diarizationEnabled.toggle()
  }

  func shutdown() async {
    if case .recording = state {
      await stopCapture()
    }
  }

  // MARK: - Per-source pipeline

  private func runSource(_ source: CaptureSource) async throws {
    let coreSource: ChronicleCore.CaptureSource
    switch source {
    case .mic: coreSource = .mic
    case .sysaudio: coreSource = .sysaudio
    }
    let sourceTag = coreSource.rawValue

    // 1. Output paths
    let paths = try SessionOutputPaths.defaults(source: sourceTag)
    await MainActor.run { sessionOutputURL = paths.sessionDir }

    // 2. Transcription engine
    let requestedLocale = Locale.current
    let engine = try await TranscriptionEngine.make(
      locale: requestedLocale,
      preset: .progressiveTranscription,
      tag: sourceTag
    )
    let transcriber = engine.transcriber
    let analyzer = engine.analyzer
    guard let analyzerFormat = engine.analyzerFormat else {
      throw CaptureManagerError.noAnalyzerFormat
    }

    // 3. Audio source
    let audioSource: AudioSource
    switch source {
    case .mic:
      audioSource = try MicAudioSource(analyzerFormat: analyzerFormat)
    case .sysaudio:
      audioSource = CoreAudioTapSource(analyzerFormat: analyzerFormat)
    }

    // 4. Compose sinks
    var sinks: [TranscriptionSink] = []
    sinks.append(try JSONLTraceSink(
      url: paths.trace,
      source: sourceTag,
      sourceKind: source == .mic ? .microphone : .systemOutput,
      locale: engine.locale.identifier,
      preset: TranscriptionEngine.presetName(.progressiveTranscription),
      recordTranscriptionLatency: true
    ))
    sinks.append(LiveFileSink(url: paths.live))
    sinks.append(FinalsAppendSink(url: paths.finals))
    sinks.append(transcriptSink)

    // 5. Optional diarizer + multicast
    let diarizer: SortformerStreamingDiarizer? = settings.diarizationEnabled
      ? SortformerStreamingDiarizer(logTag: "\(sourceTag).diarize")
      : nil

    let needsMulticast = diarizer != nil
    let pcmMulticast: BufferMulticast<PCMBufferRef>?
    let sidecarStream: AsyncStream<PCMBufferRef>
    let diarizerStream: AsyncStream<PCMBufferRef>?
    if needsMulticast {
      let mc = BufferMulticast<PCMBufferRef>()
      pcmMulticast = mc
      sidecarStream = mc.subscribe()
      diarizerStream = mc.subscribe()
    } else {
      pcmMulticast = nil
      sidecarStream = audioSource.pcmBuffers
      diarizerStream = nil
    }

    // 6. Audio sidecar (ALAC default)
    let audioSink: AudioSidecarSink?
    let audioPath = paths.sessionDir.appendingPathComponent("audio.caf").path
    audioSink = try? AVAudioFileALACSink(
      url: URL(fileURLWithPath: audioPath),
      sourceFormat: analyzerFormat
    )

    // 7. Prewarm diarizer
    if let diarizer {
      try? await diarizer.prepare()
    }

    // 8. Start audio source
    try await audioSource.start()

    // 9. Fan-out multicast
    let multicastTask: Task<Void, Never>? = pcmMulticast.map { mc in
      Task {
        for await ref in audioSource.pcmBuffers {
          mc.yield(ref)
        }
        mc.finish()
      }
    }

    // 10. Diarizer ingestion
    let diarizerTask: Task<Void, Never>? = diarizer.flatMap { d in
      diarizerStream.map { stream in
        Task {
          for await ref in stream {
            try? await d.ingest(ref)
          }
        }
      }
    }

    // 11. Audio sidecar writer
    let pcmTask = Task {
      for await ref in sidecarStream {
        if let sink = audioSink {
          await sink.append(ref.buffer)
        }
      }
    }

    // 12. Start analyzer + consume results
    let resultClock = LiveResultClock()
    resultClock.markStarted()
    try await analyzer.start(inputSequence: audioSource.analyzerInputs)

    let consumeTask = Task {
      for try await result in transcriber.results {
        guard !Task.isCancelled else { break }
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
        for sink in sinks {
          await sink.didReceiveResult(
            text,
            isFinal: result.isFinal,
            wallclockOffsetMs: offsetMs,
            wallclock: wallclock,
            audioRange: audioRange,
            speakerId: speakerId
          )
        }
      }
    }

    // 13. Wait for cancellation (stopCapture sets the task cancelled)
    while !Task.isCancelled {
      try await Task.sleep(for: .milliseconds(250))
    }

    // 14. Finalize
    audioSource.stop()
    do {
      try await withTimeout(seconds: 5.0, label: "analyzer.finalize") {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      }
    } catch is TimeoutError {
      try? await withTimeout(seconds: 2.0, label: "analyzer.cancelAndFinishNow") {
        await analyzer.cancelAndFinishNow()
      }
    }
    _ = try? await consumeTask.value
    _ = await pcmTask.value
    await multicastTask?.value
    await diarizerTask?.value
    if let diarizer { await diarizer.finish() }
    if let audioSink { await audioSink.finish() }
    for sink in sinks {
      await sink.finish()
    }
  }
}

// MARK: - Errors

enum CaptureManagerError: Error, CustomStringConvertible {
  case noAnalyzerFormat

  var description: String {
    switch self {
    case .noAnalyzerFormat:
      "Could not resolve a compatible audio format for SpeechAnalyzer."
    }
  }
}
