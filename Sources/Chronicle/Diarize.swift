import ArgumentParser
import Foundation

struct Diarize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diarize",
    abstract: "TODO: Diarize subcommand."
  )

  func run() async throws {
    print("[diarize] not implemented yet")
    throw ExitCode(2)
  }
}
