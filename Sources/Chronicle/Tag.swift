import ArgumentParser
import Foundation

struct Tag: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tag",
    abstract: "TODO: Tag subcommand."
  )

  func run() async throws {
    print("[tag] not implemented yet")
    throw ExitCode(2)
  }
}
