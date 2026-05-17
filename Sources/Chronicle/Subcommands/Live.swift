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

  @Option(name: [.long, .customShort("o")], help: "Append source-aware volatile + final events to this JSONL trace path.")
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
    let engine = try await TranscriptionEngine.make(
      locale: requestedLocale,
      preset: .progressiveTranscription,
      tag: "live"
    )
    let supported = engine.locale
    let transcriber = engine.transcriber
    let analyzer = engine.analyzer

    let startMonotonic = ContinuousClock.now
    let traceSink: JSONLTraceSink?
    var sinks: [TranscriptionSink] = []
    if let output = self.output {
      let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
      FileHandle.standardError.write(Data("[INFO] [live] appending JSONL trace to \(url.path)\n".utf8))
      let sink = try JSONLTraceSink(
        url: url,
        source: "live",
        sourceKind: .file,
        locale: supported.identifier,
        preset: TranscriptionEngine.presetName(.progressiveTranscription)
      )
      traceSink = sink
      sinks.append(sink)
    } else {
      traceSink = nil
    }
    let composedSinks = sinks

    let consumeTask = Task {
      var volatileCount = 0
      var finalCount = 0
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let offset = MonotonicClock.milliseconds(since: startMonotonic)
        let wallclock = Date()
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(result.range.end)
        let audioRange = start.isFinite && end.isFinite
          ? TraceAudioRange(startSeconds: start, endSeconds: end)
          : nil
        for sink in composedSinks {
          await sink.didReceiveResult(
            text,
            isFinal: result.isFinal,
            wallclockOffsetMs: offset,
            wallclock: wallclock,
            audioRange: audioRange
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
          print("\u{1b}[32mFINAL\u{1b}[0m \(String(format: "%6.2f", start))s: \(text)")
        } else {
          volatileCount += 1
          print("\u{1b}[33mvolatile\u{1b}[0m \(String(format: "%6.2f", start))s: \(text)")
        }
      }
      return (volatileCount, finalCount)
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
    let counts: (volatile: Int, final: Int)
    do {
      counts = try await consumeTask.value
    } catch {
      for sink in composedSinks {
        await sink.finish()
      }
      if let traceSink {
        let stats = await traceSink.stats()
        FileHandle.standardError.write(Data(
          "[live] trace.written=\(stats.writtenEvents) trace.dropped=\(stats.droppedEvents)\n".utf8
        ))
      }
      throw error
    }
    for sink in composedSinks {
      await sink.finish()
    }
    let elapsed = Date().timeIntervalSince(startedStreaming)

    FileHandle.standardError.write(Data(
      "[live] elapsed=\(String(format: "%.2f", elapsed))s audio=\(String(format: "%.2f", audioDuration))s rtf=\(String(format: "%.1f", audioDuration / elapsed))x volatile=\(counts.volatile) final=\(counts.final)\n".utf8
    ))
    if let traceSink {
      let stats = await traceSink.stats()
      FileHandle.standardError.write(Data(
        "[live] trace.written=\(stats.writtenEvents) trace.dropped=\(stats.droppedEvents)\n".utf8
      ))
      if stats.droppedEvents > 0 {
        throw ExitCode(3)
      }
    }
  }
}
