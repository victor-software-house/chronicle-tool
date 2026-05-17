import Foundation
import Testing
@testable import Chronicle

@Suite("BufferMulticast")
struct BufferMulticastTests {
  @Test("single subscriber receives every yielded value in order")
  func singleSubscriberReceivesAllValues() async {
    let mc = BufferMulticast<Int>(bufferCapacity: 16)
    let stream = mc.subscribe()
    let task = Task<[Int], Never> {
      var out: [Int] = []
      for await value in stream { out.append(value) }
      return out
    }
    for i in 0..<10 { mc.yield(i) }
    mc.finish()
    let received = await task.value
    #expect(received == Array(0..<10))
  }

  @Test("multiple subscribers each receive every yielded value")
  func multipleSubscribersFanOut() async {
    // Capacity is generous so a fan-out test under parallel test load does
    // not get starved by other tests' tasks before the consumers schedule.
    let mc = BufferMulticast<Int>(bufferCapacity: 1024)
    let a = mc.subscribe()
    let b = mc.subscribe()
    let c = mc.subscribe()

    func collect(_ s: AsyncStream<Int>) -> Task<[Int], Never> {
      Task<[Int], Never> {
        var out: [Int] = []
        for await value in s { out.append(value) }
        return out
      }
    }
    let ta = collect(a)
    let tb = collect(b)
    let tc = collect(c)

    let expected = Array(0..<25)
    for i in expected {
      mc.yield(i)
      await Task.yield()
    }
    mc.finish()

    #expect(await ta.value == expected)
    #expect(await tb.value == expected)
    #expect(await tc.value == expected)
  }

  @Test("slow subscriber drops under bounded queue without blocking fast subscriber")
  func slowSubscriberDropsOldest() async {
    let mc = BufferMulticast<Int>(bufferCapacity: 4)

    // Fast subscriber drains via a tight async loop.
    let fast = mc.subscribe()
    let fastTask = Task<[Int], Never> {
      var out: [Int] = []
      for await v in fast { out.append(v) }
      return out
    }
    // Slow subscriber registers but does not consume until after yields.
    let slow = mc.subscribe()

    // Yield with a cooperative await between each so the fast consumer
    // gets scheduled and drains. Slow consumer never reads, so its
    // bounded queue saturates and drops.
    let total = 50
    for i in 0..<total {
      mc.yield(i)
      await Task.yield()
    }
    mc.finish()

    var slowReceived: [Int] = []
    for await v in slow { slowReceived.append(v) }
    let fastReceived = await fastTask.value

    #expect(fastReceived == Array(0..<total))
    #expect(slowReceived.count <= 4)
    if let firstSlow = slowReceived.first, let lastSlow = slowReceived.last {
      // Survivors must remain in monotonic order and form a subsequence
      // of the original yield order.
      #expect(firstSlow <= lastSlow)
      let asSet = Set(slowReceived)
      let asContiguous = Array(firstSlow...lastSlow)
      #expect(asSet.isSubset(of: Set(asContiguous)))
    }
    #expect(mc.droppedCount >= total - 4)
  }

  @Test("finish drains existing subscribers and yields are no-ops afterwards")
  func finishDrainsSubscribers() async {
    let mc = BufferMulticast<Int>(bufferCapacity: 8)
    let s = mc.subscribe()
    mc.yield(1)
    mc.yield(2)
    mc.finish()
    // Yields after finish are silently ignored.
    mc.yield(3)
    mc.yield(4)
    var received: [Int] = []
    for await v in s { received.append(v) }
    #expect(received == [1, 2])
    #expect(mc.subscriberCount == 0)
  }

  @Test("late subscriber after finish gets an empty finished stream")
  func lateSubscriberAfterFinishGetsEmptyStream() async {
    let mc = BufferMulticast<Int>(bufferCapacity: 8)
    mc.yield(99)
    mc.finish()
    let late = mc.subscribe()
    var received: [Int] = []
    for await v in late { received.append(v) }
    #expect(received.isEmpty)
  }

  @Test("subscriber count tracks add/remove via stream termination")
  func subscriberCountTracksLifecycle() async {
    let mc = BufferMulticast<Int>(bufferCapacity: 8)
    #expect(mc.subscriberCount == 0)

    // Outer scope keeps task alive long enough to observe count growing.
    let task = Task {
      let stream = mc.subscribe()
      for await _ in stream {}
    }
    // Yield until subscriber registers.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(mc.subscriberCount == 1)

    task.cancel()
    // Cancelling the consumer ends iteration; AsyncStream calls
    // onTermination which removes the subscriber.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(mc.subscriberCount == 0)
  }
}
