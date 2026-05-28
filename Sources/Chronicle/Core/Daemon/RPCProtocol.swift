import Foundation

public enum RPCID: Codable, Equatable, Sendable {
  case string(String)
  case number(Int)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      self = .number(try container.decode(Int.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    }
  }
}

public enum RPCErrorCode: String, Codable, Equatable, Sendable {
  case malformedRequest = "malformed_request"
  case unsupportedMethod = "unsupported_method"
  case resourceBusy = "resource_busy"
  case invalidConfig = "invalid_config"
  case daemonUnavailable = "daemon_unavailable"
}

public struct RPCError: Codable, Equatable, Sendable {
  public let code: RPCErrorCode
  public let message: String
  public let retriable: Bool
  public let hint: String
  public let details: [String: JSONValue]?

  public init(
    code: RPCErrorCode,
    message: String,
    retriable: Bool,
    hint: String,
    details: [String: JSONValue]? = nil
  ) {
    self.code = code
    self.message = message
    self.retriable = retriable
    self.hint = hint
    self.details = details
  }
}

public enum RPCProtocolError: Error, Equatable, Sendable {
  case malformedRequest(RPCError)
}

public struct RPCRequest: Codable, Equatable, Sendable {
  public let jsonrpc: String
  public let id: RPCID?
  public let method: String
  public let params: [String: JSONValue]?

  public init(jsonrpc: String = "2.0", id: RPCID?, method: String, params: [String: JSONValue]? = nil) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.method = method
    self.params = params
  }

  public static func decode(_ data: Data) throws -> RPCRequest {
    do {
      let request = try RPCProtocol.decoder().decode(RPCRequest.self, from: data)
      guard request.jsonrpc == "2.0", !request.method.isEmpty else {
        throw RPCProtocolError.malformedRequest(.malformedRequest(hint: "Send a valid JSON-RPC 2.0 request with a non-empty method."))
      }
      return request
    } catch let error as RPCProtocolError {
      throw error
    } catch {
      throw RPCProtocolError.malformedRequest(.malformedRequest(hint: "Send valid JSON-RPC 2.0 JSON."))
    }
  }
}

public struct RPCResponse: Codable, Equatable, Sendable {
  public let jsonrpc: String
  public let id: RPCID?
  public let result: [String: JSONValue]?
  public let error: RPCError?

  public init(jsonrpc: String = "2.0", id: RPCID?, result: [String: JSONValue]?, error: RPCError?) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.result = result
    self.error = error
  }

  public static func success(id: RPCID?, result: [String: JSONValue]) -> RPCResponse {
    RPCResponse(id: id, result: result, error: nil)
  }

  public static func failure(id: RPCID?, error: RPCError) -> RPCResponse {
    RPCResponse(id: id, result: nil, error: error)
  }

  public func encodedString() -> String {
    let data = (try? RPCProtocol.encoder().encode(self)) ?? Data(#"{"jsonrpc":"2.0","error":{"code":"malformed_request","message":"failed to encode response","retriable":false,"hint":"Report this Chronicle bug."}}"#.utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

public struct RPCNotification: Codable, Equatable, Sendable {
  public let jsonrpc = "2.0"
  public let method: String
  public let params: [String: JSONValue]?

  public init(method: String, params: [String: JSONValue]? = nil) {
    self.method = method
    self.params = params
  }

  public func encodedString() throws -> String {
    let data = try RPCProtocol.encoder().encode(self)
    return String(decoding: data, as: UTF8.self)
  }

  enum CodingKeys: String, CodingKey {
    case jsonrpc
    case method
    case params
  }
}

public enum RPCProtocol {
  public static func handleDecodeFailure(_ data: Data) -> RPCResponse {
    let error = RPCError.malformedRequest(hint: "Send valid JSON-RPC 2.0 JSON.")
    return .failure(id: nil, error: error)
  }

  public static func dispatch(_ request: RPCRequest, supportedMethods: Set<String>) -> RPCResponse {
    if request.method == "meta.schema" {
      do {
        return .success(id: request.id, result: try OpenRPCSchema.current().resultObject())
      } catch {
        return .failure(
          id: request.id,
          error: RPCError(
            code: .malformedRequest,
            message: "Failed to encode schema",
            retriable: false,
            hint: "Report this Chronicle schema encoding bug."
          )
        )
      }
    }

    guard supportedMethods.contains(request.method) else {
      return .failure(
        id: request.id,
        error: RPCError(
          code: .unsupportedMethod,
          message: "Unsupported method: \(request.method)",
          retriable: false,
          hint: "Call meta.schema to discover supported Chronicle daemon methods.",
          details: ["method": .string(request.method)]
        )
      )
    }

    return .success(id: request.id, result: ["accepted": .bool(true)])
  }

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    JSONDecoder()
  }
}

private extension RPCError {
  static func malformedRequest(hint: String) -> RPCError {
    RPCError(
      code: .malformedRequest,
      message: "Malformed request",
      retriable: false,
      hint: hint
    )
  }
}
