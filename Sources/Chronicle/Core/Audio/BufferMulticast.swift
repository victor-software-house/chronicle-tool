import Foundation

/// Generic fan-out helper for live audio buffer streams.
///
/// Per-source `AudioSource` implementations already expose `analyzerInputs`
/// (for `SpeechAnalyzer`) and `pcmBuffers` (for one sidecar consumer). FR-4
/// adds a streaming diarizer as a third consumer of the same audio. To avoid
/// re-running the source's converter and to keep the source callback
/// non-blocking, the existing `pcmBuffers` stream is wrapped in a single
/// `BufferMulticast` whose subscribers each get their own `AsyncStream`.
///
/// Design contract:
///
/// * `subscribe()` is safe to call before `start()`. Each subscriber gets
///   their own `AsyncStream<Element>` with an independent bounded buffer.
/// * `yield(_:)` returns immediately. It is safe to call from a real-time
///   audio thread: each subscriber's continuation is non-blocking and uses
///   `.bufferingOldest(capacity)` so a slow consumer drops its oldest
///   queued elements rather than blocking faster consumers or the source.
/// * `finish()` finishes every existing subscriber's stream. Late subscribers
///   created after `finish()` receive a finished (empty) stream.
/// * Element type is generic so the helper is unit-testable with `Int` while
///   still being usable with `PCMBufferRef` in the live pipeline.
///
/// Concurrency: subscriber registration and yield/finish all mutate an
/// internal lock-protected continuation array. The lock is held only long
/// enough to copy a continuation snapshot; yields run outside the lock so a
/// stalled audio callback cannot stall registration and vice versa.
public final class BufferMulticast<Element: Sendable>: @unchecked Sendable {
  /// Default per-subscriber queue depth. Streaming-diarizer windows accept
  /// ~1 s of 16 kHz mono float buffers (typically 10-20 PCM buffers); 512
  /// gives generous headroom while bounding memory if a subscriber stalls.
  public static var defaultBufferCapacity: Int { 512 }

  private struct Subscriber {
    let id: Int
    let continuation: AsyncStream<Element>.Continuation
  }

  private let lock = NSLock()
  private var subscribers: [Subscriber] = []
  private var nextId: Int = 0
  private var isFinished: Bool = false
  private let bufferCapacity: Int
  private(set) public var droppedCount: Int = 0

  public init(bufferCapacity: Int = BufferMulticast.defaultBufferCapacity) {
    self.bufferCapacity = bufferCapacity
  }

  /// Register a new consumer. Returns an `AsyncStream<Element>` plus a
  /// cancel handle that removes the subscription before its buffer drains.
  /// If the multicast is already finished, the returned stream is finished.
  public func subscribe() -> AsyncStream<Element> {
    AsyncStream(bufferingPolicy: .bufferingOldest(bufferCapacity)) { continuation in
      let id = lock.withLock { () -> Int in
        if isFinished {
          continuation.finish()
          return -1
        }
        let id = nextId
        nextId += 1
        subscribers.append(Subscriber(id: id, continuation: continuation))
        return id
      }
      guard id >= 0 else { return }
      continuation.onTermination = { @Sendable [weak self] _ in
        self?.unsubscribe(id: id)
      }
    }
  }

  /// Forward one element to every current subscriber. Non-blocking.
  public func yield(_ element: Element) {
    let snapshot = lock.withLock { subscribers }
    for sub in snapshot {
      let result = sub.continuation.yield(element)
      switch result {
      case .dropped:
        lock.withLock { droppedCount += 1 }
      default:
        break
      }
    }
  }

  /// Finish every subscriber's stream. Idempotent.
  public func finish() {
    let snapshot = lock.withLock { () -> [Subscriber] in
      let subs = subscribers
      subscribers.removeAll()
      isFinished = true
      return subs
    }
    for sub in snapshot {
      sub.continuation.finish()
    }
  }

  /// Test/diagnostic accessor for the current subscriber count.
  public var subscriberCount: Int {
    lock.withLock { subscribers.count }
  }

  private func unsubscribe(id: Int) {
    lock.withLock {
      subscribers.removeAll { $0.id == id }
    }
  }
}
