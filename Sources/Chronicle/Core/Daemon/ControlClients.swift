import Foundation

/// Thin RPC client wrappers for the start/stop/status command surface.
///
/// These types only serialize JSON-RPC requests, send them through a Unix
/// domain socket via `ChronicleRPCClient`, and surface a structured
/// `daemon_unavailable` response when the daemon socket is missing. They
/// never open audio, TCC, or sidecar resources.

public enum StatusClient {
  public static func fetch(paths: RuntimePaths, id: RPCID = .string(UUID().uuidString.lowercased())) async -> RPCResponse {
    let request = RPCRequest(
      id: id,
      method: "status.get",
      params: ["source": .string(paths.source.rawValue)]
    )
    return await ChronicleRPCClient(socketURL: paths.socketURL).sendOrStructuredError(request)
  }
}

public enum StartClient {
  public static func send(
    paths: RuntimePaths,
    clientRequestID: ClientRequestID,
    id: RPCID = .string(UUID().uuidString.lowercased())
  ) async -> RPCResponse {
    let request = RPCRequest(
      id: id,
      method: "capture.ensure",
      params: [
        "source": .string(paths.source.rawValue),
        "client_req_id": .string(clientRequestID.rawValue),
      ]
    )
    return await ChronicleRPCClient(socketURL: paths.socketURL).sendOrStructuredError(request)
  }
}

public enum StopClient {
  public static func send(
    paths: RuntimePaths,
    clientRequestID: ClientRequestID,
    id: RPCID = .string(UUID().uuidString.lowercased())
  ) async -> RPCResponse {
    let request = RPCRequest(
      id: id,
      method: "capture.stop",
      params: [
        "source": .string(paths.source.rawValue),
        "client_req_id": .string(clientRequestID.rawValue),
      ]
    )
    return await ChronicleRPCClient(socketURL: paths.socketURL).sendOrStructuredError(request)
  }
}
