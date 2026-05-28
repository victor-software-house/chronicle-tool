import Foundation
import Testing
@testable import Chronicle

@Suite("RPCTransport")
struct RPCTransportTests {
  @Test("local socket round-trips meta.schema and status.get")
  func localSocketRoundTripsSchemaAndStatus() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
    let server = RPCServer(paths: paths)
    try server.start()
    defer { server.stop() }

    let client = ChronicleRPCClient(socketURL: paths.socketURL)
    let schema = try await client.send(RPCRequest(id: .string("schema"), method: "meta.schema"))
    #expect(schema.error == nil)
    #expect(schema.result?["protocolVersion"] == .string("1.0"))
    #expect(schema.encodedString().contains("status.get"))

    let status = try await client.send(RPCRequest(id: .string("status"), method: "status.get", params: ["source": .string("mic")]))
    #expect(status.error == nil)
    #expect(status.result?["source"] == .string("mic"))
    #expect(status.result?["lifecycle"] == .string("stopped"))
  }

  @Test("daemon unavailable uses structured error shape")
  func daemonUnavailableUsesStructuredErrorShape() async throws {
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot())
    defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
    let client = ChronicleRPCClient(socketURL: paths.socketURL)

    let response = await client.sendOrStructuredError(RPCRequest(id: .string("status"), method: "status.get"))
    #expect(response.id == .string("status"))
    #expect(response.error?.code == .daemonUnavailable)
    #expect(response.error?.retriable == true)
    #expect(response.error?.hint.contains("daemon") == true)
  }

  @Test("malformed socket request returns structured error")
  func malformedSocketRequestReturnsStructuredError() async throws {
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot())
    defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
    let server = RPCServer(paths: paths)
    try server.start()
    defer { server.stop() }

    let raw = try await ChronicleRPCClient.sendRaw("not-json\n", to: paths.socketURL)
    #expect(raw.contains("malformed_request"))
    #expect(raw.contains("retriable"))
    #expect(!raw.contains("Swift"))
    #expect(!raw.contains("Backtrace"))
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("crpc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
