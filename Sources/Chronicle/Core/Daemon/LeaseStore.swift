import Foundation

public struct LeaseID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func fresh() -> LeaseID {
    LeaseID(rawValue: UUID().uuidString.lowercased())
  }
}

public struct Lease: Codable, Equatable, Sendable {
  public let id: LeaseID
  public let source: CaptureSource
  public let purpose: String
  public let holder: String
  public let acquiredAt: Date
  public let expiresAt: Date
}

public enum LeaseStoreError: Error, Equatable, Sendable {
  case leaseNotFound(LeaseID)
  case invalidTTL(TimeInterval)
}

/// TTL coordination leases for multi-step client operations.
///
/// Leases coordinate clients only. They do not own or open a physical capture
/// source; `SourceOwner` remains the exclusive capture gate.
public struct LeaseStore: Sendable {
  public let epoch: DaemonEpoch
  public let source: CaptureSource
  public private(set) var events: [DaemonEvent] = []

  private var leases: [LeaseID: Lease] = [:]
  private var nextSequence = 1

  public init(epoch: DaemonEpoch, source: CaptureSource) {
    self.epoch = epoch
    self.source = source
  }

  @discardableResult
  public mutating func acquire(
    purpose: String,
    holder: String,
    ttl: TimeInterval,
    now: Date = Date()
  ) throws -> Lease {
    guard ttl > 0 else { throw LeaseStoreError.invalidTTL(ttl) }
    let lease = Lease(
      id: .fresh(),
      source: source,
      purpose: purpose,
      holder: holder,
      acquiredAt: now,
      expiresAt: now.addingTimeInterval(ttl)
    )
    leases[lease.id] = lease
    appendEvent(type: "lease.acquired", lease: lease, now: now)
    return lease
  }

  @discardableResult
  public mutating func renew(id: LeaseID, ttl: TimeInterval, now: Date = Date()) throws -> Lease {
    guard ttl > 0 else { throw LeaseStoreError.invalidTTL(ttl) }
    guard let existing = leases[id] else { throw LeaseStoreError.leaseNotFound(id) }
    let renewed = Lease(
      id: existing.id,
      source: existing.source,
      purpose: existing.purpose,
      holder: existing.holder,
      acquiredAt: existing.acquiredAt,
      expiresAt: now.addingTimeInterval(ttl)
    )
    leases[id] = renewed
    appendEvent(type: "lease.renewed", lease: renewed, now: now)
    return renewed
  }

  @discardableResult
  public mutating func release(id: LeaseID, now: Date = Date()) throws -> Lease {
    guard let lease = leases.removeValue(forKey: id) else { throw LeaseStoreError.leaseNotFound(id) }
    appendEvent(type: "lease.released", lease: lease, now: now)
    return lease
  }

  @discardableResult
  public mutating func expire(now: Date = Date()) -> [Lease] {
    let expired = leases.values
      .filter { $0.expiresAt <= now }
      .sorted { $0.expiresAt < $1.expiresAt }
    for lease in expired {
      leases.removeValue(forKey: lease.id)
      appendEvent(type: "lease.expired", lease: lease, now: now)
    }
    return expired
  }

  public func activeLeases(now: Date = Date()) -> [Lease] {
    leases.values
      .filter { $0.expiresAt > now }
      .sorted { lhs, rhs in
        if lhs.expiresAt == rhs.expiresAt { return lhs.id.rawValue < rhs.id.rawValue }
        return lhs.expiresAt < rhs.expiresAt
      }
  }

  private mutating func appendEvent(type: String, lease: Lease, now: Date) {
    events.append(DaemonEvent(
      sequence: nextSequence,
      epoch: epoch,
      source: source,
      stream: .control,
      monotonicSeconds: ProcessInfo.processInfo.systemUptime,
      wallClock: now,
      type: type,
      payload: [
        "lease_id": .string(lease.id.rawValue),
        "purpose": .string(lease.purpose),
        "holder": .string(lease.holder),
        "expires_at": .string(iso8601(lease.expiresAt)),
      ]
    ))
    nextSequence += 1
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
