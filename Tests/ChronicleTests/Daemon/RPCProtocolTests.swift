import Foundation
import Testing
@testable import Chronicle

@Suite("RPCProtocol")
struct RPCProtocolTests {
  @Test("decodes valid request and enforces jsonrpc version")
  func decodesValidRequestAndEnforcesJSONRPCVersion() throws {
    let request = try RPCRequest.decode(Data(#"{"jsonrpc":"2.0","id":"req-1","method":"status.get","params":{"source":"mic"}}"#.utf8))
    #expect(request.id == .string("req-1"))
    #expect(request.method == "status.get")
    #expect(request.params?["source"] == .string("mic"))

    #expect(throws: RPCProtocolError.self) {
      _ = try RPCRequest.decode(Data(#"{"jsonrpc":"1.0","id":"req-1","method":"status.get"}"#.utf8))
    }
  }

  @Test("malformed JSON returns structured stack-trace-free error")
  func malformedJSONReturnsStructuredStackTraceFreeError() {
    let response = RPCProtocol.handleDecodeFailure(Data(#"{"jsonrpc":"2.0","id":"bad","method":"#.utf8))
    #expect(response.jsonrpc == "2.0")
    #expect(response.id == nil)
    #expect(response.error?.code == .malformedRequest)
    #expect(response.error?.retriable == false)
    #expect(response.error?.hint.contains("valid JSON-RPC") == true)
    #expect(!response.encodedString().contains("Swift"))
    #expect(!response.encodedString().contains("stack"))
  }

  @Test("unsupported method returns structured non-retriable error")
  func unsupportedMethodReturnsStructuredNonRetriableError() throws {
    let request = try RPCRequest.decode(Data(#"{"jsonrpc":"2.0","id":7,"method":"unknown.method"}"#.utf8))
    let response = RPCProtocol.dispatch(request, supportedMethods: ["status.get", "meta.schema"])

    #expect(response.id == .number(7))
    #expect(response.result == nil)
    #expect(response.error?.code == .unsupportedMethod)
    #expect(response.error?.retriable == false)
    #expect(response.error?.hint.contains("meta.schema") == true)
    #expect(response.error?.details?["method"] == .string("unknown.method"))
  }

  @Test("success response and notification envelopes encode expected shape")
  func successResponseAndNotificationEnvelopesEncodeExpectedShape() throws {
    let response = RPCResponse.success(id: .string("req-2"), result: ["state": .string("stopped")])
    let responseJSON = response.encodedString()
    #expect(responseJSON.contains(#""jsonrpc":"2.0""#))
    #expect(responseJSON.contains(#""state":"stopped""#))
    #expect(!responseJSON.contains(#""error""#))

    let notification = RPCNotification(method: "events.next", params: ["type": .string("heartbeat")])
    let notificationJSON = try notification.encodedString()
    #expect(notificationJSON.contains(#""jsonrpc":"2.0""#))
    #expect(notificationJSON.contains(#""method":"events.next""#))
    #expect(!notificationJSON.contains(#""id""#))
  }

  @Test("normal error envelope carries stable code retriable hint and details")
  func normalErrorEnvelopeCarriesStableCodeRetriableHintAndDetails() {
    let response = RPCResponse.failure(
      id: .string("req-3"),
      error: RPCError(
        code: .resourceBusy,
        message: "source already owned",
        retriable: true,
        hint: "Attach to the existing owner or stop it first.",
        details: ["source": .string("sysaudio")]
      )
    )

    #expect(response.error?.code.rawValue == "resource_busy")
    #expect(response.error?.retriable == true)
    #expect(response.error?.hint == "Attach to the existing owner or stop it first.")
    #expect(response.error?.details?["source"] == .string("sysaudio"))
    #expect(!response.encodedString().contains("Backtrace"))
  }
}
