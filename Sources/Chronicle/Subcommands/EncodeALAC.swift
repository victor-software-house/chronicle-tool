import ChronicleCore
import ArgumentParser
import ChronicleCore
import AVFAudio
import ChronicleCore
import Foundation

/// Offline re-encoder: streams an input audio file through `AVAudioFileALACSink`
/// to produce a lossless Apple Lossless artefact that exercises chronicle's
/// preferred high-level production sink path. Counterpart to `EncodeOpus`; used
/// by the PRD-001 P11 verification parity sweep with `FORMAT=alac`.
struct EncodeALAC: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "encode-alac",
    abstract: "Re-encode an audio file to ALAC-in-CAF via AVAudioFileALACSink (PRD-001 P11 verification helper)."
  )

  @Option(name: [.long, .customShort("i")], help: "Input audio file (wav/m4a/mp3/flac).")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output ALAC-in-CAF path (.caf).")
  var output: String

  @Option(name: .long, help: "Read chunk size in frames (default 4096 — matches ALAC packet).")
  var chunkFrames: UInt32 = 4_096

  func run() async throws {
    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw ValidationError("Input file does not exist: \(inputURL.path)")
    }
    let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let audioFile = try AVAudioFile(forReading: inputURL)
    let sourceFormat = audioFile.processingFormat
    let totalFrames = audioFile.length
    let durationSeconds = Double(totalFrames) / sourceFormat.sampleRate

    let sink = try AVAudioFileALACSink(url: outputURL, sourceFormat: sourceFormat)

    let started = Date()
    var framesProcessed: AVAudioFramePosition = 0
    let chunkCapacity = AVAudioFrameCount(chunkFrames)

    while audioFile.framePosition < totalFrames {
      guard let buf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkCapacity) else {
        throw ValidationError("Failed to allocate input PCM buffer (capacity \(chunkCapacity)).")
      }
      try audioFile.read(into: buf, frameCount: chunkCapacity)
      if buf.frameLength == 0 { break }
      await sink.append(buf)
      framesProcessed += AVAudioFramePosition(buf.frameLength)
    }
    await sink.finish()

    let elapsed = Date().timeIntervalSince(started)
    let outBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
    let rtf = durationSeconds > 0 ? durationSeconds / elapsed : 0

    FileHandle.standardError.write(Data(
      "[encode-alac] audio=\(String(format: "%.2f", durationSeconds))s framesIn=\(framesProcessed) elapsed=\(String(format: "%.2f", elapsed))s rtf=\(String(format: "%.1f", rtf))x outBytes=\(outBytes)\n".utf8
    ))
    FileHandle.standardError.write(Data("[encode-alac] wrote \(outputURL.path)\n".utf8))
  }
}
