import Foundation
import Testing
@testable import Chronicle

@Suite("OpenRPCSchema")
struct OpenRPCSchemaTests {
  @Test("schema lists every registered daemon method")
  func schemaListsEveryRegisteredDaemonMethod() {
    let schema = OpenRPCSchema.current()
    let methodNames = Set(schema.methods.map(\.name))

    #expect(schema.protocolVersion == "1.0")
    #expect(schema.compatibilityVersion == 1)
    #expect(methodNames == OpenRPCSchema.registeredMethodNames)
    #expect(methodNames.isSuperset(of: [
      "meta.schema",
      "status.get",
      "capture.ensure",
      "capture.stop",
      "capture.reconfigure",
      "events.subscribe",
      "mark.create",
      "clip.create",
      "lease.acquire",
      "lease.renew",
      "lease.release",
    ]))
  }

  @Test("mutating methods declare client_req_id request field")
  func mutatingMethodsDeclareClientRequestIDRequestField() {
    let schema = OpenRPCSchema.current()
    let mutatingMethods = schema.methods.filter(\.mutating)
    #expect(!mutatingMethods.isEmpty)

    for method in mutatingMethods {
      #expect(method.requestFields.contains { field in
        field.name == "client_req_id" && field.required
      }, "\(method.name) must require client_req_id")
    }
  }

  @Test("schema covers events errors and examples")
  func schemaCoversEventsErrorsAndExamples() {
    let schema = OpenRPCSchema.current()

    #expect(Set(schema.events.map(\.name)).isSuperset(of: [
      "daemon.recovery",
      "heartbeat",
      "capture.starting",
      "marker.created",
      "lease.acquired",
      "lease.released",
      "subscriber_lagged",
    ]))
    #expect(Set(schema.errorCodes.map(\.code)).isSuperset(of: [
      .malformedRequest,
      .unsupportedMethod,
      .resourceBusy,
      .daemonUnavailable,
    ]))
    #expect(schema.examples.contains { $0.method == "meta.schema" })
    #expect(schema.examples.contains { $0.method == "capture.ensure" && $0.request.contains("client_req_id") })
  }

  @Test("meta.schema dispatch returns schema response")
  func metaSchemaDispatchReturnsSchemaResponse() throws {
    let request = RPCRequest(id: .string("schema-1"), method: "meta.schema")
    let response = RPCProtocol.dispatch(request, supportedMethods: OpenRPCSchema.registeredMethodNames)

    #expect(response.error == nil)
    #expect(response.result?["protocolVersion"] == .string("1.0"))
    #expect(response.result?["compatibilityVersion"] == .number(1))
    #expect(response.result?["methods"] != nil)
    #expect(response.encodedString().contains("capture.ensure"))
  }

  @Test("schema is codable and includes request response field contracts")
  func schemaIsCodableAndIncludesFieldContracts() throws {
    let schema = OpenRPCSchema.current()
    let encoded = try RPCProtocol.encoder().encode(schema)
    let decoded = try RPCProtocol.decoder().decode(OpenRPCSchema.self, from: encoded)

    #expect(decoded == schema)
    let status = try #require(decoded.methods.first { $0.name == "status.get" })
    #expect(status.requestFields.contains { $0.name == "source" && !$0.required })
    #expect(status.responseFields.contains { $0.name == "lifecycle" })
  }

  @Test("lease.* methods are advertised as supported mutating RPC methods")
  func leaseMethodsAreAdvertisedAsSupportedMutatingRPCMethods() {
    let schema = OpenRPCSchema.current()
    for name in ["lease.acquire", "lease.renew", "lease.release"] {
      let method = schema.methods.first { $0.name == name }
      #expect(method != nil, "schema must register \(name)")
      #expect(method?.mutating == true)
      #expect(method?.requestFields.contains { $0.name == "client_req_id" && $0.required } == true)
    }
  }
}
