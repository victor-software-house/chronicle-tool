import Foundation
import Testing
@testable import Chronicle

@Suite("Daemon command registration")
struct DaemonCommandRegistrationTests {
  @Test("chronicle CLI registers daemon subcommands")
  func chronicleCLIRegistersDaemonSubcommands() {
    let names = Chronicle.configuration.subcommands.map { $0.configuration.commandName ?? "" }
    let required = ["daemon-run", "start", "stop", "status", "tail", "mark", "clip", "config"]
    for name in required {
      #expect(names.contains(name), "missing chronicle subcommand: \(name)")
    }
  }

  @Test("start command does not open audio when daemon unavailable")
  func startCommandDoesNotOpenAudioWhenDaemonUnavailable() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let response = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "noop"))
    #expect(response.error?.code == .daemonUnavailable)
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cregi-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
