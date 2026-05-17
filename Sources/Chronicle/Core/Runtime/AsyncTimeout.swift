import Foundation

/// Generic timeout wrapper for an `async throws` operation.
///
/// Races `operation` against a sleep. Whichever finishes first wins; the
/// loser is cancelled. If the sleep wins, the call throws `TimeoutError`
/// and the caller can surface a clear, actionable error rather than
/// leaking a stuck continuation.
///
/// Designed for guarding system-API calls that can silently hang when an
/// OS precondition is in a bad state.
///
/// **Important caveat**: this wrapper can only force-stop work that
/// responds to Task cancellation. Truly leaked OS continuations are
/// **not** rescuable here — the inner await never resumes and Task
/// cancellation has no entry point. For those system APIs, pair this
/// timeout with a non-blocking preflight check or post-start telemetry
/// (`CoreAudioTapSource` keeps idle taps running and warns until audio flows).
/// This timeout wrapper acts as a defense-in-depth net for the cancellation-aware
/// majority of system APIs.
///
/// Example:
///
/// ```swift
/// do {
///   try await withTimeout(seconds: 10, label: "AudioDeviceStart") {
///     try await startAudioDevice()
///   }
/// } catch is TimeoutError {
///   throw AudioStartError.timedOut(seconds: 10)
/// }
/// ```
public struct TimeoutError: Error, CustomStringConvertible {
  public let seconds: Double
  public let label: String?
  public init(seconds: Double, label: String? = nil) {
    self.seconds = seconds
    self.label = label
  }
  public var description: String {
    if let label {
      return "TimeoutError: \(label) did not complete within \(seconds)s"
    }
    return "TimeoutError: operation did not complete within \(seconds)s"
  }
}

/// Race an async-throws operation against a sleep. Throws `TimeoutError`
/// if the sleep wins.
///
/// - Parameters:
///   - seconds: timeout budget.
///   - label: optional label for the `TimeoutError.description`.
///   - operation: the async work to guard.
public func withTimeout<T: Sendable>(
  seconds: Double,
  label: String? = nil,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw TimeoutError(seconds: seconds, label: label)
    }
    // First child to finish wins; cancel the rest.
    defer { group.cancelAll() }
    if let result = try await group.next() {
      return result
    }
    throw TimeoutError(seconds: seconds, label: label)
  }
}
