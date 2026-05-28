import Foundation

public struct EventFilter: Equatable, Sendable {
  public let source: CaptureSource?
  public let streams: Set<DaemonEventStream>?
  public let typePrefix: String?
  public let sinceSequence: Int?
  public let includeHeartbeat: Bool

  public init(
    source: CaptureSource? = nil,
    streams: Set<DaemonEventStream>? = nil,
    typePrefix: String? = nil,
    sinceSequence: Int? = nil,
    includeHeartbeat: Bool = true
  ) {
    self.source = source
    self.streams = streams
    self.typePrefix = typePrefix
    self.sinceSequence = sinceSequence
    self.includeHeartbeat = includeHeartbeat
  }

  public func matches(_ event: DaemonEvent) -> Bool {
    if let source, event.source != source { return false }
    if let streams, !streams.contains(event.stream) { return false }
    if let sinceSequence, event.sequence <= sinceSequence { return false }
    if let typePrefix, !event.type.hasPrefix(typePrefix) { return false }
    if !includeHeartbeat, event.stream == .heartbeat { return false }
    return true
  }
}

public final class EventSubscriber: @unchecked Sendable {
  public let id: UUID
  public let filter: EventFilter

  private let lock = NSLock()
  private var buffer: [DaemonEvent] = []
  private let bufferLimit: Int

  fileprivate init(id: UUID = UUID(), filter: EventFilter, bufferLimit: Int) {
    self.id = id
    self.filter = filter
    self.bufferLimit = max(1, bufferLimit)
  }

  fileprivate func enqueue(_ event: DaemonEvent) {
    guard filter.matches(event) else { return }
    lock.withLock {
      if buffer.count >= bufferLimit {
        let newest = event
        let lag = DaemonEvent(
          sequence: max(0, newest.sequence - 1),
          epoch: newest.epoch,
          source: newest.source,
          stream: .control,
          monotonicSeconds: newest.monotonicSeconds,
          wallClock: newest.wallClock,
          type: "subscriber_lagged",
          payload: [
            "subscriber_id": .string(id.uuidString),
            "dropped": .number(1),
          ]
        )
        buffer = [lag]
      }
      buffer.append(event)
    }
  }

  public func drain() -> [DaemonEvent] {
    lock.withLock {
      let drained = buffer
      buffer.removeAll(keepingCapacity: true)
      return drained
    }
  }
}

public final class EventHub: @unchecked Sendable {
  private let lock = NSLock()
  private let bufferLimit: Int
  private var subscribers: [UUID: EventSubscriber] = [:]

  public init(bufferLimit: Int = 256) {
    self.bufferLimit = max(1, bufferLimit)
  }

  public func subscribe(filter: EventFilter = EventFilter()) -> EventSubscriber {
    let subscriber = EventSubscriber(filter: filter, bufferLimit: bufferLimit)
    lock.withLock {
      subscribers[subscriber.id] = subscriber
    }
    return subscriber
  }

  public func unsubscribe(_ subscriber: EventSubscriber) {
    lock.withLock {
      _ = subscribers.removeValue(forKey: subscriber.id)
    }
  }

  public func publish(_ event: DaemonEvent) {
    let snapshot = lock.withLock { Array(subscribers.values) }
    for subscriber in snapshot {
      subscriber.enqueue(event)
    }
  }

  public var subscriberCount: Int {
    lock.withLock { subscribers.count }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
