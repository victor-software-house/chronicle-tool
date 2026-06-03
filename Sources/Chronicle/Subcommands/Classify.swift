import ChronicleCore
import ArgumentParser
import ChronicleCore
import AVFoundation
import ChronicleCore
import Foundation
import ChronicleCore
import SoundAnalysis

/// Non-speech sound classifier built on Apple's `SoundAnalysis` framework using
/// the built-in Apple-trained sound classifier (covers speech, music, animals,
/// vehicles, alarms, ~300 classes total). Useful as a pre-gate for STT to
/// skip non-speech audio without uploading anything.
///
/// References:
/// - https://developer.apple.com/documentation/soundanalysis/sn-classifier
/// - https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest
@available(macOS 13.0, *)
struct Classify: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "classify",
    abstract: "Sound classification via Apple SoundAnalysis (on-device, free; speech-gate use case)."
  )

  @Option(name: [.long, .customShort("i")], help: "Input audio file (any AVAudioFile-readable format).")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output JSON path. Writes per-window classifications.")
  var output: String

  @Option(name: .long, help: "Confidence threshold for emitting a label (0.0-1.0).")
  var threshold: Double = 0.3

  @Option(name: .long, help: "Only keep labels matching this substring (case-insensitive). Repeat by passing a comma-separated list.")
  var filter: String?

  @Flag(name: .long, help: "Compact mode: only emit windows whose top label contains 'speech'.")
  var speechOnly: Bool = false

  func run() async throws {
    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw ValidationError("Input file does not exist: \(inputURL.path)")
    }

    let audioFile = try AVAudioFile(forReading: inputURL)
    let format = audioFile.processingFormat
    let totalDuration = Double(audioFile.length) / format.sampleRate
    FileHandle.standardError.write(Data("[classify] audio=\(String(format: "%.2f", totalDuration))s format=\(format)\n".utf8))

    let analyzer = try SNAudioFileAnalyzer(url: inputURL)

    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)

    struct Window: Codable {
      let startSeconds: Double
      let endSeconds: Double
      let labels: [Label]
    }
    struct Label: Codable {
      let identifier: String
      let confidence: Double
    }

    final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
      var windows: [Window] = []
      let threshold: Double
      let filters: [String]
      let speechOnly: Bool
      init(threshold: Double, filters: [String], speechOnly: Bool) {
        self.threshold = threshold
        self.filters = filters
        self.speechOnly = speechOnly
      }
      func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        var labels: [Label] = []
        for c in r.classifications {
          guard c.confidence >= threshold else { continue }
          let id = c.identifier.lowercased()
          if !filters.isEmpty, !filters.contains(where: { id.contains($0) }) { continue }
          labels.append(Label(identifier: c.identifier, confidence: c.confidence))
        }
        if speechOnly {
          guard labels.first?.identifier.lowercased().contains("speech") == true else { return }
        }
        guard !labels.isEmpty else { return }
        windows.append(Window(
          startSeconds: r.timeRange.start.seconds,
          endSeconds: (r.timeRange.start + r.timeRange.duration).seconds,
          labels: labels
        ))
      }
      func request(_ request: SNRequest, didFailWithError error: Error) {
        FileHandle.standardError.write(Data("[classify] error: \(error)\n".utf8))
      }
      func requestDidComplete(_ request: SNRequest) {}
    }

    let filters = (filter ?? "").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty }
    let observer = Observer(threshold: threshold, filters: filters, speechOnly: speechOnly)
    try analyzer.add(request, withObserver: observer)

    let started = Date()
    await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        analyzer.analyze()
        cont.resume()
      }
    }
    let elapsed = Date().timeIntervalSince(started)

    let speechSeconds = observer.windows
      .filter { $0.labels.first?.identifier.lowercased().contains("speech") == true }
      .reduce(0.0) { $0 + ($1.endSeconds - $1.startSeconds) }

    struct Doc: Codable {
      let inputPath: String
      let audioDurationSeconds: Double
      let elapsedSeconds: Double
      let realtimeFactor: Double
      let threshold: Double
      let filters: [String]
      let speechOnly: Bool
      let windowCount: Int
      let speechSeconds: Double
      let speechRatio: Double
      let windows: [Window]
    }
    let doc = Doc(
      inputPath: inputURL.path,
      audioDurationSeconds: totalDuration,
      elapsedSeconds: elapsed,
      realtimeFactor: totalDuration > 0 ? totalDuration / elapsed : 0,
      threshold: threshold,
      filters: filters,
      speechOnly: speechOnly,
      windowCount: observer.windows.count,
      speechSeconds: speechSeconds,
      speechRatio: totalDuration > 0 ? speechSeconds / totalDuration : 0,
      windows: observer.windows
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let outURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    try encoder.encode(doc).write(to: outURL)

    FileHandle.standardError.write(Data(
      "[classify] windows=\(observer.windows.count) speech=\(String(format: "%.1f", speechSeconds))s (\(String(format: "%.1f", doc.speechRatio * 100))%) elapsed=\(String(format: "%.2f", elapsed))s rtf=\(String(format: "%.1f", doc.realtimeFactor))x\n".utf8
    ))
    FileHandle.standardError.write(Data("[classify] wrote \(outURL.path)\n".utf8))
  }
}
