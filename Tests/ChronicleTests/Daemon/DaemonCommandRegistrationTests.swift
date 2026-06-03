import Foundation
import Testing
@testable import Chronicle
@testable import ChronicleCore

@Suite("Daemon command registration")
struct DaemonCommandRegistrationTests {
  @Test("chronicle CLI nests daemon verbs under `chronicle daemon`")
  func chronicleCLINestsDaemonVerbsUnderDaemon() {
    let topLevel = Chronicle.configuration.subcommands.map { $0.configuration.commandName ?? "" }
    #expect(topLevel.contains("daemon"))
    // Flat daemon verbs must no longer collide with mic / sysaudio / live.
    #expect(!topLevel.contains("daemon-run"))
    #expect(!topLevel.contains("start"))
    #expect(!topLevel.contains("stop"))
    #expect(!topLevel.contains("status"))
    #expect(!topLevel.contains("tail"))
    #expect(!topLevel.contains("mark"))
    #expect(!topLevel.contains("clip"))
    #expect(!topLevel.contains("config"))

    let daemonGroup = Chronicle.configuration.subcommands.first { $0.configuration.commandName == "daemon" }
    let nested = (daemonGroup?.configuration.subcommands ?? []).map { $0.configuration.commandName ?? "" }
    let required = ["run", "start", "stop", "status", "tail", "mark", "clip", "config"]
    for name in required {
      #expect(nested.contains(name), "missing chronicle daemon subcommand: \(name)")
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
