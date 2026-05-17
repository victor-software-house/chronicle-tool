import Foundation

public enum MonotonicClock {
  public static func milliseconds(since start: ContinuousClock.Instant, now: ContinuousClock.Instant = .now) -> Double {
    let elapsed = start.duration(to: now)
    let components = elapsed.components
    return (Double(components.seconds) * 1000.0) + (Double(components.attoseconds) / 1_000_000_000_000_000.0)
  }
}
