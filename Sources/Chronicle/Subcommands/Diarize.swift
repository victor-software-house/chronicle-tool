import ArgumentParser
import Foundation
import FluidAudio

/// Speaker diarization via FluidAudio's offline VBx pipeline (CoreML, Neural
/// Engine). Apple ships no diarization API on macOS 26; FluidAudio is the
/// production-quality option for "who spoke when".
///
/// Models are downloaded into the user's caches on first run. All inference
/// runs on the ANE.
struct Diarize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diarize",
    abstract: "Speaker diarization via FluidAudio (CoreML, Neural Engine, on-device, free)."
  )

  @Option(name: [.long, .customShort("i")], help: "Input audio file (any format AudioConverter accepts).")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output JSON path (segments with speakerId + start/end seconds).")
  var output: String

  @Flag(name: .long, help: "Print one line per segment to stdout in addition to writing the JSON file.")
  var stdout: Bool = false

  func run() async throws {
    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw ValidationError("Input file does not exist: \(inputURL.path)")
    }

    FileHandle.standardError.write(Data("[diarize] downloading or loading FluidAudio diarizer models...\n".utf8))
    let models = try await DiarizerModels.downloadIfNeeded()
    FileHandle.standardError.write(Data("[diarize] models ready\n".utf8))

    let diarizer = DiarizerManager()
    diarizer.initialize(models: models)

    let converter = AudioConverter()
    let samples = try converter.resampleAudioFile(inputURL)
    let sampleCount = samples.count
    let durationSec = Double(sampleCount) / 16_000.0
    FileHandle.standardError.write(Data("[diarize] audio=\(String(format: "%.2f", durationSec))s samples=\(sampleCount) @ 16kHz mono float32\n".utf8))

    let started = Date()
    let result = try await diarizer.performCompleteDiarization(samples)
    let elapsed = Date().timeIntervalSince(started)

    struct Segment: Codable {
      let speakerId: String
      let startSeconds: Double
      let endSeconds: Double
    }
    struct Doc: Codable {
      let inputPath: String
      let audioDurationSeconds: Double
      let elapsedSeconds: Double
      let realtimeFactor: Double
      let speakerCount: Int
      let segmentCount: Int
      let segments: [Segment]
    }

    let segs = result.segments.map { Segment(
      speakerId: $0.speakerId,
      startSeconds: Double($0.startTimeSeconds),
      endSeconds: Double($0.endTimeSeconds)
    ) }
    let speakers = Set(segs.map(\.speakerId))

    let doc = Doc(
      inputPath: inputURL.path,
      audioDurationSeconds: durationSec,
      elapsedSeconds: elapsed,
      realtimeFactor: durationSec > 0 ? durationSec / elapsed : 0,
      speakerCount: speakers.count,
      segmentCount: segs.count,
      segments: segs
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let outURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    try encoder.encode(doc).write(to: outURL)

    FileHandle.standardError.write(Data(
      "[diarize] speakers=\(speakers.count) segments=\(segs.count) elapsed=\(String(format: "%.2f", elapsed))s rtf=\(String(format: "%.1f", doc.realtimeFactor))x\n".utf8
    ))
    FileHandle.standardError.write(Data("[diarize] wrote \(outURL.path)\n".utf8))

    if stdout {
      for s in segs {
        print("\(s.speakerId)\t\(String(format: "%.2f", s.startSeconds))\t\(String(format: "%.2f", s.endSeconds))")
      }
    }
  }
}
