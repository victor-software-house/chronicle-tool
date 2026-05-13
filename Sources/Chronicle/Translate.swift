import ArgumentParser
import Foundation

struct Translate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "translate",
    abstract: "TODO: Translate subcommand."
  )

  func run() async throws {
    print("[translate] not implemented yet")
    throw ExitCode(2)
  }
}
