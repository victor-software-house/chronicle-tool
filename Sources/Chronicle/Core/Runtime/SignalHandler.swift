import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One-shot wrapper so `SIGINT` and `SIGTERM` both call `resume()` at most once
/// without crashing on the second signal. Used by daemons that block on a
/// `CheckedContinuation` until either signal arrives.
public final class OneShotResume: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private let continuation: CheckedContinuation<Void, Never>
  public init(continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }
  public func fire() {
    lock.lock(); defer { lock.unlock() }
    guard !fired else { return }
    fired = true
    continuation.resume()
  }
}

/// Block the calling task until `SIGINT` or `SIGTERM` arrives.
///
/// Suspends the default signal handlers via `SIG_IGN`, installs
/// `DispatchSource` handlers for both signals, and returns when either
/// fires. Safe to call once per process.
public enum SignalHandler {
  public static func waitForTermination() async {
    let intSource = DispatchSource.makeSignalSource(signal: SIGINT)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      let resumeOnce = OneShotResume(continuation: cont)
      intSource.setEventHandler { resumeOnce.fire() }
      termSource.setEventHandler { resumeOnce.fire() }
      intSource.resume()
      termSource.resume()
    }
    intSource.cancel()
    termSource.cancel()
  }
}
