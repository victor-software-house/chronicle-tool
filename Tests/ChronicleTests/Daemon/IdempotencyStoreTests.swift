import Foundation
import Testing
@testable import Chronicle

@Suite("IdempotencyStore")
struct IdempotencyStoreTests {
  @Test("replays same successful mutating request outcome")
  func replaysSameSuccessfulMutatingRequestOutcome() throws {
    var store = IdempotencyStore(epoch: DaemonEpoch(rawValue: "epoch"))
    let request = RPCRequest(id: .string("rpc-1"), method: "capture.ensure", params: ["source": .string("mic"), "client_req_id": .string("req-1")])
    let response = RPCResponse.success(id: .string("rpc-1"), result: ["lifecycle": .string("capturing")])

    #expect(try store.record(request: request, response: response, source: .mic, now: Date(timeIntervalSince1970: 10)) == .stored(response))
    #expect(try store.record(request: request, response: RPCResponse.success(id: .string("rpc-2"), result: ["ignored": .bool(true)]), source: .mic, now: Date(timeIntervalSince1970: 11)) == .replayed(response))
  }

  @Test("replays same structured error outcome")
  func replaysSameStructuredErrorOutcome() throws {
    var store = IdempotencyStore(epoch: DaemonEpoch(rawValue: "epoch"))
    let request = RPCRequest(id: .string("rpc-1"), method: "capture.stop", params: ["source": .string("sysaudio"), "client_req_id": .string("req-err")])
    let response = RPCResponse.failure(id: .string("rpc-1"), error: RPCError(code: .daemonUnavailable, message: "daemon unavailable", retriable: true, hint: "retry later"))

    _ = try store.record(request: request, response: response, source: .sysaudio, now: Date(timeIntervalSince1970: 10))
    #expect(try store.record(request: request, response: RPCResponse.success(id: .string("rpc-2"), result: [:]), source: .sysaudio, now: Date(timeIntervalSince1970: 12)) == .replayed(response))
  }

  @Test("rejects conflicting payload for reused client request id")
  func rejectsConflictingPayloadForReusedClientRequestID() throws {
    var store = IdempotencyStore(epoch: DaemonEpoch(rawValue: "epoch"))
    let first = RPCRequest(id: .string("rpc-1"), method: "capture.ensure", params: ["source": .string("mic"), "client_req_id": .string("req-1")])
    let second = RPCRequest(id: .string("rpc-2"), method: "capture.ensure", params: ["source": .string("sysaudio"), "client_req_id": .string("req-1")])
    let response = RPCResponse.success(id: .string("rpc-1"), result: ["lifecycle": .string("capturing")])

    _ = try store.record(request: first, response: response, source: .mic)
    #expect(throws: IdempotencyStoreError.self) {
      _ = try store.record(request: second, response: response, source: .sysaudio)
    }
  }

  @Test("non mutating or missing client_req_id requests are ignored")
  func nonMutatingOrMissingClientRequestIDRequestsAreIgnored() throws {
    var store = IdempotencyStore(epoch: DaemonEpoch(rawValue: "epoch"))
    let status = RPCRequest(id: .string("status"), method: "status.get", params: ["source": .string("mic")])
    let missing = RPCRequest(id: .string("ensure"), method: "capture.ensure", params: ["source": .string("mic")])
    let response = RPCResponse.success(id: .string("status"), result: [:])

    #expect(try store.record(request: status, response: response, source: .mic) == .ignored)
    #expect(try store.record(request: missing, response: response, source: .mic) == .ignored)
  }

  @Test("snapshot includes source epoch timestamp and method")
  func snapshotIncludesSourceEpochTimestampAndMethod() throws {
    var store = IdempotencyStore(epoch: DaemonEpoch(rawValue: "epoch"))
    let request = RPCRequest(id: .string("rpc-1"), method: "mark.create", params: ["source": .string("mic"), "client_req_id": .string("mark-1"), "label": .string("demo")])
    let response = RPCResponse.success(id: .string("rpc-1"), result: ["ok": .bool(true)])
    let now = Date(timeIntervalSince1970: 42)

    _ = try store.record(request: request, response: response, source: .mic, now: now)
    let entries = store.snapshot()
    #expect(entries.count == 1)
    #expect(entries[0].method == "mark.create")
    #expect(entries[0].clientRequestID == ClientRequestID(rawValue: "mark-1"))
    #expect(entries[0].source == .mic)
    #expect(entries[0].epoch == DaemonEpoch(rawValue: "epoch"))
    #expect(entries[0].storedAt == now)
  }
}
