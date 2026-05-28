import Foundation

public enum MarkClient {
  public static func send(
    paths: RuntimePaths,
    label: String,
    clientRequestID: ClientRequestID,
    id: RPCID = .string(UUID().uuidString.lowercased())
  ) async -> RPCResponse {
    let request = RPCRequest(
      id: id,
      method: "mark.create",
      params: [
        "source": .string(paths.source.rawValue),
        "label": .string(label),
        "client_req_id": .string(clientRequestID.rawValue),
      ]
    )
    return await ChronicleRPCClient(socketURL: paths.socketURL).sendOrStructuredError(request)
  }
}

public enum ClipClient {
  public static func send(
    paths: RuntimePaths,
    request clipRequest: ClipRequest,
    clientRequestID: ClientRequestID,
    id: RPCID = .string(UUID().uuidString.lowercased())
  ) async -> RPCResponse {
    let request = RPCRequest(
      id: id,
      method: "clip.create",
      params: [
        "source": .string(paths.source.rawValue),
        "last_seconds": .number(clipRequest.lastSeconds),
        "output": .string(clipRequest.outputURL.path),
        "client_req_id": .string(clientRequestID.rawValue),
      ]
    )
    return await ChronicleRPCClient(socketURL: paths.socketURL).sendOrStructuredError(request)
  }
}

public enum ConfigClient {
  public static func send(
    paths: RuntimePaths,
    change: LiveCaptureChange,
    clientRequestID: ClientRequestID,
    id: RPCID = .string(UUID().uuidString.lowercased())
  ) async -> RPCResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let changeJSON = (try? encoder.encode(change)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let request = RPCRequest(
      id: id,
      method: "capture.reconfigure",
      params: [
        "source": .string(paths.source.rawValue),
        "change": .string(changeJSON),
        "client_req_id": .string(clientRequestID.rawValue),
      ]
    )
    return await ChronicleRPCClient(socketURL: paths.socketURL).sendOrStructuredError(request)
  }
}

public struct TailRequest: Equatable, Sendable {
  public let source: CaptureSource
  public let streams: [DaemonEventStream]?
  public let typePrefix: String?
  public let sinceSequence: Int?
  public let includeHeartbeat: Bool

  public init(source: CaptureSource, streams: [DaemonEventStream]? = nil, typePrefix: String? = nil, sinceSequence: Int? = nil, includeHeartbeat: Bool = true) {
    self.source = source
    self.streams = streams
    self.typePrefix = typePrefix
    self.sinceSequence = sinceSequence
    self.includeHeartbeat = includeHeartbeat
  }

  public func rpcRequest(id: RPCID) -> RPCRequest {
    var params: [String: JSONValue] = [
      "source": .string(source.rawValue),
      "include_heartbeat": .bool(includeHeartbeat),
    ]
    if let streams {
      params["streams"] = .string(streams.map(\.rawValue).joined(separator: ","))
    }
    if let typePrefix {
      params["type_prefix"] = .string(typePrefix)
    }
    if let sinceSequence {
      params["since_sequence"] = .number(Double(sinceSequence))
    }
    return RPCRequest(id: id, method: "events.subscribe", params: params)
  }
}

public enum TailClient {
  public static func send(
    paths: RuntimePaths,
    request: TailRequest,
    id: RPCID = .string(UUID().uuidString.lowercased())
  ) async -> RPCResponse {
    let rpc = request.rpcRequest(id: id)
    return await ChronicleRPCClient(socketURL: paths.socketURL).sendOrStructuredError(rpc)
  }

  /// Render a single `DaemonEvent` JSON line for stdout tail consumers.
  public static func renderEventLine(_ event: DaemonEvent) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) else { return "" }
    return line
  }
}
