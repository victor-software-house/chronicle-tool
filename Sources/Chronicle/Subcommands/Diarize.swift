import ChronicleCore
import ArgumentParser
import ChronicleCore
import Foundation

/// Speaker diarization CLI veneer over `Core/Diarize/OfflineDiarizer`.
///
/// Streaming variant (FR-4) is `StreamingDiarizer` and is wired into the
/// `mic` / `sysaudio` daemons rather than exposed as a standalone subcommand.
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

    let diarizer = OfflineDiarizer(logTag: "diarize")
    let result = try await diarizer.diarizeFile(inputURL)

    struct Doc: Codable {
      let inputPath: String
      let audioDurationSeconds: Double
      let elapsedSeconds: Double
      let realtimeFactor: Double
      let speakerCount: Int
      let segmentCount: Int
      let segments: [DiarizationSegment]
    }

    let doc = Doc(
      inputPath: inputURL.path,
      audioDurationSeconds: result.audioDurationSeconds,
      elapsedSeconds: result.elapsedSeconds,
      realtimeFactor: result.realtimeFactor,
      speakerCount: result.speakerIds.count,
      segmentCount: result.segments.count,
      segments: result.segments
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let outURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    try encoder.encode(doc).write(to: outURL)

    FileHandle.standardError.write(Data(
      "[diarize] speakers=\(result.speakerIds.count) segments=\(result.segments.count) elapsed=\(String(format: "%.2f", result.elapsedSeconds))s rtf=\(String(format: "%.1f", result.realtimeFactor))x\n".utf8
    ))
    FileHandle.standardError.write(Data("[diarize] wrote \(outURL.path)\n".utf8))

    if stdout {
      for s in result.segments {
        print("\(s.speakerId)\t\(String(format: "%.2f", s.startSeconds))\t\(String(format: "%.2f", s.endSeconds))")
      }
    }
  }
}
