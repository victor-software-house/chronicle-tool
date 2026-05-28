import Foundation

/// Minimal JSON payload value used by daemon control/event records.
public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

/// Durable daemon event streams owned by the control plane.
public enum DaemonEventStream: String, CaseIterable, Codable, Hashable, Sendable {
  case manifest
  case control
  case heartbeat
}

/// Versioned daemon event envelope.
public struct DaemonEvent: Codable, Equatable, Sendable {
  public let version: Int
  public let sequence: Int
  public let epoch: DaemonEpoch
  public let source: CaptureSource
  public let stream: DaemonEventStream
  public let monotonicSeconds: Double
  public let wallClock: Date
  public let type: String
  public let payload: [String: JSONValue]

  public init(
    version: Int = 1,
    sequence: Int,
    epoch: DaemonEpoch,
    source: CaptureSource,
    stream: DaemonEventStream,
    monotonicSeconds: Double,
    wallClock: Date,
    type: String,
    payload: [String: JSONValue] = [:]
  ) {
    self.version = version
    self.sequence = sequence
    self.epoch = epoch
    self.source = source
    self.stream = stream
    self.monotonicSeconds = monotonicSeconds
    self.wallClock = wallClock
    self.type = type
    self.payload = payload
  }

  public func withSequence(_ sequence: Int) -> DaemonEvent {
    DaemonEvent(
      version: version,
      sequence: sequence,
      epoch: epoch,
      source: source,
      stream: stream,
      monotonicSeconds: monotonicSeconds,
      wallClock: wallClock,
      type: type,
      payload: payload
    )
  }

  enum CodingKeys: String, CodingKey {
    case version = "v"
    case sequence = "seq"
    case epoch
    case source
    case stream
    case monotonicSeconds = "t_mono"
    case wallClock = "t_wall"
    case type
    case payload
  }
}
