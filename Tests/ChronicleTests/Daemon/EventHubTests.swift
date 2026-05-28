import Foundation
import Testing
@testable import Chronicle

@Suite("EventHub")
struct EventHubTests {
  @Test("filters events by source stream type prefix and since sequence")
  func filtersEventsBySourceStreamTypePrefixAndSinceSequence() {
    let events = [
      event(seq: 1, source: .mic, stream: .control, type: "capture.started"),
      event(seq: 2, source: .sysaudio, stream: .heartbeat, type: "heartbeat"),
      event(seq: 3, source: .mic, stream: .control, type: "capture.reconfigure.succeeded"),
    ]
    let filter = EventFilter(source: .mic, streams: [.control], typePrefix: "capture.", sinceSequence: 1, includeHeartbeat: false)

    #expect(events.filter { filter.matches($0) }.map(\.sequence) == [3])
  }

  @Test("heartbeat inclusion controls heartbeat delivery")
  func heartbeatInclusionControlsHeartbeatDelivery() {
    let heartbeat = event(seq: 1, source: .sysaudio, stream: .heartbeat, type: "heartbeat")
    #expect(!EventFilter(source: .sysaudio, includeHeartbeat: false).matches(heartbeat))
    #expect(EventFilter(source: .sysaudio, includeHeartbeat: true).matches(heartbeat))
  }

  @Test("event hub fanout delivers matching events to subscribers")
  func eventHubFanoutDeliversMatchingEventsToSubscribers() {
    let hub = EventHub(bufferLimit: 8)
    let mic = hub.subscribe(filter: EventFilter(source: .mic, includeHeartbeat: true))
    let sys = hub.subscribe(filter: EventFilter(source: .sysaudio, includeHeartbeat: true))

    hub.publish(event(seq: 1, source: .mic, stream: .control, type: "capture.started"))
    hub.publish(event(seq: 2, source: .sysaudio, stream: .control, type: "capture.started"))

    #expect(mic.drain().map(\.source) == [.mic])
    #expect(sys.drain().map(\.source) == [.sysaudio])
  }

  @Test("slow subscriber receives lag event without blocking publisher")
  func slowSubscriberReceivesLagEventWithoutBlockingPublisher() {
    let hub = EventHub(bufferLimit: 2)
    let subscriber = hub.subscribe(filter: EventFilter(source: .mic, includeHeartbeat: true))

    hub.publish(event(seq: 1, source: .mic, stream: .control, type: "one"))
    hub.publish(event(seq: 2, source: .mic, stream: .control, type: "two"))
    hub.publish(event(seq: 3, source: .mic, stream: .control, type: "three"))

    let delivered = subscriber.drain()
    #expect(delivered.contains { $0.type == "subscriber_lagged" })
    #expect(delivered.last?.sequence == 3)
  }

  private func event(seq: Int, source: CaptureSource, stream: DaemonEventStream, type: String) -> DaemonEvent {
    DaemonEvent(sequence: seq, epoch: DaemonEpoch(rawValue: "epoch"), source: source, stream: stream, monotonicSeconds: Double(seq), wallClock: Date(timeIntervalSince1970: Double(seq)), type: type)
  }
}
