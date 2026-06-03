import Foundation
import Testing
@testable import ChronicleCore

@Suite("LeaseStore")
struct LeaseStoreTests {
  @Test("acquire renew and release lease without owning physical source")
  func acquireRenewAndReleaseLeaseWithoutOwningPhysicalSource() throws {
    var store = LeaseStore(epoch: DaemonEpoch(rawValue: "epoch"), source: .mic)
    let now = Date(timeIntervalSince1970: 100)

    let acquired = try store.acquire(purpose: "clip", holder: "agent", ttl: 30, now: now)
    #expect(acquired.source == .mic)
    #expect(acquired.purpose == "clip")
    #expect(acquired.holder == "agent")
    #expect(acquired.expiresAt == Date(timeIntervalSince1970: 130))
    #expect(store.activeLeases(now: now).map(\.id) == [acquired.id])

    let renewed = try store.renew(id: acquired.id, ttl: 60, now: Date(timeIntervalSince1970: 120))
    #expect(renewed.expiresAt == Date(timeIntervalSince1970: 180))

    let released = try store.release(id: acquired.id, now: Date(timeIntervalSince1970: 121))
    #expect(released.id == acquired.id)
    #expect(store.activeLeases(now: Date(timeIntervalSince1970: 122)).isEmpty)
  }

  @Test("expiry removes orphaned coordination state and records event")
  func expiryRemovesOrphanedCoordinationStateAndRecordsEvent() throws {
    var store = LeaseStore(epoch: DaemonEpoch(rawValue: "epoch"), source: .sysaudio)
    let lease = try store.acquire(purpose: "recent_clip", holder: "agent", ttl: 10, now: Date(timeIntervalSince1970: 10))

    let expired = store.expire(now: Date(timeIntervalSince1970: 21))
    #expect(expired.map(\.id) == [lease.id])
    #expect(store.activeLeases(now: Date(timeIntervalSince1970: 21)).isEmpty)

    let events = store.events
    #expect(events.contains { $0.type == "lease.acquired" && $0.payload["lease_id"] == .string(lease.id.rawValue) })
    #expect(events.contains { $0.type == "lease.expired" && $0.payload["lease_id"] == .string(lease.id.rawValue) })
  }

  @Test("release and renew missing lease return structured errors")
  func releaseAndRenewMissingLeaseReturnStructuredErrors() throws {
    var store = LeaseStore(epoch: DaemonEpoch(rawValue: "epoch"), source: .mic)
    let missing = LeaseID(rawValue: "missing")

    #expect(throws: LeaseStoreError.self) {
      _ = try store.renew(id: missing, ttl: 5)
    }
    #expect(throws: LeaseStoreError.self) {
      _ = try store.release(id: missing)
    }
  }

  @Test("lease lifecycle events are source epoch and sequence aware")
  func leaseLifecycleEventsAreSourceEpochAndSequenceAware() throws {
    var store = LeaseStore(epoch: DaemonEpoch(rawValue: "epoch"), source: .mic)
    let lease = try store.acquire(purpose: "marker", holder: "agent", ttl: 30, now: Date(timeIntervalSince1970: 1))
    _ = try store.release(id: lease.id, now: Date(timeIntervalSince1970: 2))

    #expect(store.events.map(\.sequence) == [1, 2])
    #expect(Set(store.events.map(\.source)) == [.mic])
    #expect(Set(store.events.map(\.epoch)) == [DaemonEpoch(rawValue: "epoch")])
    #expect(store.events.map(\.stream) == [.control, .control])
  }
}
