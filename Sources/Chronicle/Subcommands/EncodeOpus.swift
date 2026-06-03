import ChronicleCore
import ArgumentParser
import ChronicleCore
import AVFAudio
import ChronicleCore
import Foundation

/// Offline re-encoder: streams an input audio file through `OpusCAFSink` to
/// produce an Opus-in-CAF artefact that exercises chronicle's production sink
/// path. Primary consumer: PRD-001 P11 verification (#50) — WER parity between
/// the original WAV and the Opus-encoded round-trip should be ≤ 1 %.
///
/// Not part of the live capture pipeline. Operator runs this manually against
/// the 2026-05-13 Zoom reference (`mic-master.wav`, 6870 s) or any saved file.
struct EncodeOpus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "encode-opus",
    abstract: "Re-encode an audio file to Opus-in-CAF via OpusCAFSink (PRD-001 P11 verification helper)."
  )

  @Option(name: [.long, .customShort("i")], help: "Input audio file (wav/m4a/mp3/flac).")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output Opus-in-CAF path (.caf).")
  var output: String

  @Option(name: .long, help: "Opus encode bitrate in bits/sec (default 24000).")
  var bitrate: Int = OpusCAFSink.defaultBitRate

  @Option(name: .long, help: "Read chunk size in frames (default 4096).")
  var chunkFrames: UInt32 = 4096

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

    let sink = try OpusCAFSink(
      url: outputURL,
      sourceFormat: sourceFormat,
      bitRate: bitrate
    )

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
      "[encode-opus] audio=\(String(format: "%.2f", durationSeconds))s framesIn=\(framesProcessed) elapsed=\(String(format: "%.2f", elapsed))s rtf=\(String(format: "%.1f", rtf))x bitrate=\(bitrate) outBytes=\(outBytes)\n".utf8
    ))
    FileHandle.standardError.write(Data("[encode-opus] wrote \(outputURL.path)\n".utf8))
  }
}
