import ArgumentParser
import Foundation

struct OCR: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ocr",
    abstract: "TODO: OCR subcommand."
  )

  func run() async throws {
    print("[ocr] not implemented yet")
    throw ExitCode(2)
  }
}
