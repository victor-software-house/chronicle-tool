import ArgumentParser
import Foundation

struct Live: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "live",
    abstract: "TODO: Live subcommand."
  )

  func run() async throws {
    print("[live] not implemented yet")
    throw ExitCode(2)
  }
}
