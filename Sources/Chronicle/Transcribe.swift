import ArgumentParser
import Foundation

struct Transcribe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "transcribe",
    abstract: "TODO: Transcribe subcommand."
  )

  func run() async throws {
    print("[transcribe] not implemented yet")
    throw ExitCode(2)
  }
}
