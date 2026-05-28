import Foundation

public enum IdempotencyStoreResult: Equatable, Sendable {
  case ignored
  case stored(RPCResponse)
  case replayed(RPCResponse)
}

public enum IdempotencyStoreError: Error, Equatable, Sendable {
  case conflict(existing: IdempotencyEntry)
}

public struct IdempotencyEntry: Codable, Equatable, Sendable {
  public let method: String
  public let clientRequestID: ClientRequestID
  public let source: CaptureSource
  public let epoch: DaemonEpoch
  public let storedAt: Date
  public let requestFingerprint: String
  public let response: RPCResponse
}

/// In-memory replay cache for mutating JSON-RPC requests.
///
/// The key is `(method, client_req_id)`. A retry with the same request gets the
/// exact previously recorded success or error response; reuse of the key with a
/// materially different payload is rejected as an idempotency conflict.
public struct IdempotencyStore: Sendable {
  public let epoch: DaemonEpoch
  private var entries: [String: IdempotencyEntry] = [:]

  public init(epoch: DaemonEpoch) {
    self.epoch = epoch
  }

  public mutating func record(
    request: RPCRequest,
    response: RPCResponse,
    source: CaptureSource,
    now: Date = Date()
  ) throws -> IdempotencyStoreResult {
    guard Self.mutatingMethods.contains(request.method),
          let clientRequestID = request.clientRequestID
    else {
      return .ignored
    }

    let key = Self.key(method: request.method, clientRequestID: clientRequestID)
    let fingerprint = Self.fingerprint(request)

    if let existing = entries[key] {
      guard existing.requestFingerprint == fingerprint else {
        throw IdempotencyStoreError.conflict(existing: existing)
      }
      return .replayed(existing.response)
    }

    let entry = IdempotencyEntry(
      method: request.method,
      clientRequestID: clientRequestID,
      source: source,
      epoch: epoch,
      storedAt: now,
      requestFingerprint: fingerprint,
      response: response
    )
    entries[key] = entry
    return .stored(response)
  }

  public func snapshot() -> [IdempotencyEntry] {
    entries.values.sorted { lhs, rhs in
      if lhs.storedAt == rhs.storedAt {
        return lhs.clientRequestID.rawValue < rhs.clientRequestID.rawValue
      }
      return lhs.storedAt < rhs.storedAt
    }
  }

  private static var mutatingMethods: Set<String> {
    Set(OpenRPCSchema.current().methods.filter(\.mutating).map(\.name))
  }

  private static func key(method: String, clientRequestID: ClientRequestID) -> String {
    "\(method)\u{0}\(clientRequestID.rawValue)"
  }

  private static func fingerprint(_ request: RPCRequest) -> String {
    let canonical = CanonicalRequest(method: request.method, params: request.params ?? [:])
    let data = (try? RPCProtocol.encoder().encode(canonical)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}

private struct CanonicalRequest: Encodable {
  let method: String
  let params: [String: JSONValue]
}

private extension RPCRequest {
  var clientRequestID: ClientRequestID? {
    guard case .string(let value)? = params?["client_req_id"], !value.isEmpty else { return nil }
    return ClientRequestID(rawValue: value)
  }
}
