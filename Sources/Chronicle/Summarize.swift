import ArgumentParser
import Foundation

struct Summarize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "summarize",
    abstract: "TODO: Summarize subcommand."
  )

  func run() async throws {
    print("[summarize] not implemented yet")
    throw ExitCode(2)
  }
}
