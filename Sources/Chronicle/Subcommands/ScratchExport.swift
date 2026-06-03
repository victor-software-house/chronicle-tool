import ChronicleCore
import ArgumentParser
import ChronicleCore
import Foundation

struct ScratchExport: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scratch-export",
    abstract: "Export raw PCM scratch segments to WAV or ALAC-in-CAF."
  )

  @Argument(help: "Scratch directory containing format.json and *.pcm segments.")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output path (.wav or .caf).")
  var output: String

  @Option(name: .long, help: "Output container: wav or alac. Inferred from .wav or .caf when omitted.")
  var format: ScratchExportFormat?

  func run() async throws {
    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    let summary = try await ScratchExporter.export(
      scratchDirectory: inputURL,
      outputURL: outputURL,
      container: format?.container
    )
    FileHandle.standardError.write(Data(
      "[scratch-export] segments=\(summary.segmentCount) frames=\(summary.framesWritten) bytesRead=\(summary.bytesRead) bytesTrimmed=\(summary.bytesTrimmed)\n".utf8
    ))
    FileHandle.standardError.write(Data("[scratch-export] wrote \(outputURL.path)\n".utf8))
  }
}

enum ScratchExportFormat: String, ExpressibleByArgument {
  case wav
  case alac

  var container: ScratchExportContainer {
    switch self {
    case .wav: return .wav
    case .alac: return .alac
    }
  }
}
