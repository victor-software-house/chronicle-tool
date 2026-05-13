import ArgumentParser
import Foundation

struct Classify: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "classify",
    abstract: "TODO: Classify subcommand."
  )

  func run() async throws {
    print("[classify] not implemented yet")
    throw ExitCode(2)
  }
}
