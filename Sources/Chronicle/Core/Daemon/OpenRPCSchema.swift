import Foundation

public struct OpenRPCSchema: Codable, Equatable, Sendable {
  public let protocolVersion: String
  public let compatibilityVersion: Int
  public let methods: [OpenRPCMethod]
  public let events: [OpenRPCEvent]
  public let errorCodes: [OpenRPCErrorCode]
  public let examples: [OpenRPCExample]

  public static let registeredMethodNames: Set<String> = [
    "meta.schema",
    "status.get",
    "capture.ensure",
    "capture.stop",
    "capture.reconfigure",
    "events.subscribe",
    "mark.create",
    "clip.create",
  ]

  public static func current() -> OpenRPCSchema {
    OpenRPCSchema(
      protocolVersion: "1.0",
      compatibilityVersion: 1,
      methods: Self.methodDefinitions,
      events: Self.eventDefinitions,
      errorCodes: Self.errorDefinitions,
      examples: Self.exampleDefinitions
    )
  }

  public func resultObject() throws -> [String: JSONValue] {
    let data = try RPCProtocol.encoder().encode(self)
    let value = try RPCProtocol.decoder().decode(JSONValue.self, from: data)
    guard case .object(let object) = value else { return [:] }
    return object
  }

  private static let sourceField = OpenRPCField(name: "source", type: "CaptureSource", required: true, description: "Capture source: sysaudio or mic.")
  private static let optionalSourceField = OpenRPCField(name: "source", type: "CaptureSource", required: false, description: "Optional capture source filter.")
  private static let clientRequestIDField = OpenRPCField(name: "client_req_id", type: "string", required: true, description: "Client-generated idempotency key required for mutating methods.")
  private static let lifecycleField = OpenRPCField(name: "lifecycle", type: "DaemonLifecycle", required: true, description: "Current daemon lifecycle state for the source.")

  private static let methodDefinitions: [OpenRPCMethod] = [
    OpenRPCMethod(
      name: "meta.schema",
      summary: "Return the self-describing control-plane schema.",
      mutating: false,
      requestFields: [],
      responseFields: [
        OpenRPCField(name: "protocolVersion", type: "string", required: true, description: "Protocol version."),
        OpenRPCField(name: "compatibilityVersion", type: "integer", required: true, description: "Breaking-change compatibility version."),
      ]
    ),
    OpenRPCMethod(
      name: "status.get",
      summary: "Return status for one source or all known sources.",
      mutating: false,
      requestFields: [optionalSourceField],
      responseFields: [sourceField, lifecycleField]
    ),
    OpenRPCMethod(
      name: "capture.ensure",
      summary: "Ensure capture is running for a source without duplicating an owner.",
      mutating: true,
      requestFields: [sourceField, clientRequestIDField, OpenRPCField(name: "config", type: "object", required: false, description: "Capture configuration.")],
      responseFields: [sourceField, lifecycleField]
    ),
    OpenRPCMethod(
      name: "capture.stop",
      summary: "Stop capture for a source idempotently.",
      mutating: true,
      requestFields: [sourceField, clientRequestIDField],
      responseFields: [sourceField, lifecycleField, OpenRPCField(name: "finalization", type: "string", required: false, description: "Graceful or escalated stop outcome.")]
    ),
    OpenRPCMethod(
      name: "capture.reconfigure",
      summary: "Apply a safe live capture configuration change.",
      mutating: true,
      requestFields: [sourceField, clientRequestIDField, OpenRPCField(name: "change", type: "object", required: true, description: "Requested hot-change payload.")],
      responseFields: [sourceField, lifecycleField]
    ),
    OpenRPCMethod(
      name: "events.subscribe",
      summary: "Subscribe to filtered daemon and transcript events.",
      mutating: false,
      requestFields: [
        optionalSourceField,
        OpenRPCField(name: "streams", type: "string", required: false, description: "Comma-separated daemon event streams (manifest, control, heartbeat)."),
        OpenRPCField(name: "type_prefix", type: "string", required: false, description: "Filter events whose type starts with this prefix."),
        OpenRPCField(name: "since_sequence", type: "number", required: false, description: "Exclusive lower bound on event sequence."),
        OpenRPCField(name: "include_heartbeat", type: "boolean", required: false, description: "Include heartbeat events (default true)."),
      ],
      responseFields: [
        sourceField,
        OpenRPCField(name: "events", type: "array", required: true, description: "Filtered durable events array (one-shot replay; streaming is a follow-up task)."),
      ]
    ),
    OpenRPCMethod(
      name: "mark.create",
      summary: "Create a timestamped marker for active capture.",
      mutating: true,
      requestFields: [optionalSourceField, clientRequestIDField, OpenRPCField(name: "label", type: "string", required: true, description: "Marker label.")],
      responseFields: [OpenRPCField(name: "event", type: "DaemonEvent", required: true, description: "Created marker event.")]
    ),
    OpenRPCMethod(
      name: "clip.create",
      summary: "Create a bounded recent clip export request.",
      mutating: true,
      requestFields: [optionalSourceField, clientRequestIDField, OpenRPCField(name: "window", type: "object", required: true, description: "Requested recent clip time window.")],
      responseFields: [OpenRPCField(name: "output", type: "string", required: false, description: "Exported clip path.")]
    ),
  ]

  private static let eventDefinitions: [OpenRPCEvent] = [
    OpenRPCEvent(name: "daemon.started", stream: .manifest, description: "Daemon started and acquired source ownership."),
    OpenRPCEvent(name: "daemon.stopped", stream: .manifest, description: "Daemon performed a graceful shutdown."),
    OpenRPCEvent(name: "daemon.recovery", stream: .manifest, description: "A daemon restarted after previous ownership state."),
    OpenRPCEvent(name: "heartbeat", stream: .heartbeat, description: "Periodic liveness and source lifecycle event."),
    OpenRPCEvent(name: "capture.starting", stream: .control, description: "Capture startup has begun."),
    OpenRPCEvent(name: "capture.started", stream: .control, description: "Capture is active."),
    OpenRPCEvent(name: "capture.stopped", stream: .control, description: "Capture stopped."),
    OpenRPCEvent(name: "capture.reconfigure.started", stream: .control, description: "A live reconfiguration request has begun."),
    OpenRPCEvent(name: "capture.reconfigure.succeeded", stream: .control, description: "A live reconfiguration request was applied."),
    OpenRPCEvent(name: "capture.reconfigure.failed", stream: .control, description: "A live reconfiguration request was rejected."),
    OpenRPCEvent(name: "marker.created", stream: .control, description: "A client-requested marker was recorded."),
    OpenRPCEvent(name: "subscriber_lagged", stream: .control, description: "A subscriber fell behind the bounded event queue."),
  ]

  private static let errorDefinitions: [OpenRPCErrorCode] = [
    OpenRPCErrorCode(code: .malformedRequest, retriable: false, description: "Request was not valid JSON-RPC 2.0."),
    OpenRPCErrorCode(code: .unsupportedMethod, retriable: false, description: "Method is not supported by this daemon."),
    OpenRPCErrorCode(code: .resourceBusy, retriable: true, description: "Source is already owned by another live capture."),
    OpenRPCErrorCode(code: .invalidConfig, retriable: false, description: "Requested configuration is invalid or unsafe while active."),
    OpenRPCErrorCode(code: .daemonUnavailable, retriable: true, description: "No daemon socket was available for the requested source."),
    OpenRPCErrorCode(code: .noActiveSession, retriable: false, description: "No active capture session is available for the requested operation."),
    OpenRPCErrorCode(code: .rangeUnavailable, retriable: false, description: "Requested clip window is outside retained sidecar data."),
  ]

  private static let exampleDefinitions: [OpenRPCExample] = [
    OpenRPCExample(method: "meta.schema", request: #"{"jsonrpc":"2.0","id":"schema-1","method":"meta.schema"}"#),
    OpenRPCExample(method: "status.get", request: #"{"jsonrpc":"2.0","id":"status-1","method":"status.get","params":{"source":"sysaudio"}}"#),
    OpenRPCExample(method: "capture.ensure", request: #"{"jsonrpc":"2.0","id":"ensure-1","method":"capture.ensure","params":{"source":"mic","client_req_id":"client-req-123"}}"#),
    OpenRPCExample(method: "capture.stop", request: #"{"jsonrpc":"2.0","id":"stop-1","method":"capture.stop","params":{"source":"mic","client_req_id":"stop-req-1"}}"#),
    OpenRPCExample(method: "mark.create", request: #"{"jsonrpc":"2.0","id":"mark-1","method":"mark.create","params":{"source":"mic","label":"checkpoint","client_req_id":"mark-req-1"}}"#),
    OpenRPCExample(method: "events.subscribe", request: #"{"jsonrpc":"2.0","id":"sub-1","method":"events.subscribe","params":{"source":"mic","streams":"control,heartbeat","include_heartbeat":true}}"#),
  ]
}

public struct OpenRPCMethod: Codable, Equatable, Sendable {
  public let name: String
  public let summary: String
  public let mutating: Bool
  public let requestFields: [OpenRPCField]
  public let responseFields: [OpenRPCField]
}

public struct OpenRPCField: Codable, Equatable, Sendable {
  public let name: String
  public let type: String
  public let required: Bool
  public let description: String
}

public struct OpenRPCEvent: Codable, Equatable, Sendable {
  public let name: String
  public let stream: DaemonEventStream
  public let description: String
}

public struct OpenRPCErrorCode: Codable, Equatable, Sendable {
  public let code: RPCErrorCode
  public let retriable: Bool
  public let description: String
}

public struct OpenRPCExample: Codable, Equatable, Sendable {
  public let method: String
  public let request: String
}
