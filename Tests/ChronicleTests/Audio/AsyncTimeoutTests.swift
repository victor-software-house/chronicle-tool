import Testing
import Foundation
@testable import Chronicle

@Suite("AsyncTimeout")
struct AsyncTimeoutTests {

  @Test("returns value when operation finishes before deadline")
  func returnsValue() async throws {
    let result: Int = try await withTimeout(seconds: 1.0) {
      try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
      return 42
    }
    #expect(result == 42)
  }

  @Test("throws TimeoutError when operation exceeds deadline")
  func throwsOnTimeout() async {
    do {
      _ = try await withTimeout(seconds: 0.1, label: "slow-op") {
        try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 s
        return 0
      }
      Issue.record("expected TimeoutError; nothing thrown")
    } catch let e as TimeoutError {
      #expect(e.seconds == 0.1)
      #expect(e.label == "slow-op")
      #expect(e.description.contains("slow-op"))
    } catch {
      Issue.record("expected TimeoutError; got \(error)")
    }
  }

  @Test("surfaces TimeoutError quickly when inner operation is cancellation-aware")
  func slowCancellableOp() async {
    // Important contract note: `withTimeout` can only force-stop work
    // that responds to Task cancellation. `Task.sleep` does; many
    // Apple system calls also do. Truly leaked OS continuations (e.g.
    // SCStream.startCapture() when TCC is unset) are unrescuable here
    // by design — the preflight check is the actual defense for those.
    let started = Date()
    do {
      _ = try await withTimeout(seconds: 0.1, label: "long-sleep") {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return 0
      }
      Issue.record("expected TimeoutError; nothing thrown")
    } catch is TimeoutError {
      let elapsed = Date().timeIntervalSince(started)
      #expect(elapsed < 0.5, "timeout should fire near the deadline; took \(elapsed)s")
    } catch {
      Issue.record("expected TimeoutError; got \(error)")
    }
  }

  @Test("propagates inner errors as-is when they fire before the timeout")
  func propagatesInnerErrors() async {
    struct Boom: Error {}
    do {
      _ = try await withTimeout(seconds: 1.0) {
        throw Boom()
      }
      Issue.record("expected Boom; nothing thrown")
    } catch is Boom {
      // OK
    } catch is TimeoutError {
      Issue.record("got TimeoutError but inner threw first")
    } catch {
      Issue.record("got unexpected error: \(error)")
    }
  }
}
