import Foundation
import NaturalLanguage

/// `--locale` flag grammar from ADR-0003.
public enum LocaleSpec: Equatable, Sendable {
  /// `--locale en-US` — disable detection; transcribe at this locale only.
  case pin(String)
  /// `--locale auto` — use operator's configured safe set, or built-in default.
  case autoDefault
  /// `--locale auto:en-US,pt-BR,es-ES` — auto with explicit candidate set.
  case autoList([String])
  /// `--locale auto:*` — opt-in research mode, full SpeechTranscriber supported set.
  case autoAny

  /// Parse the textual form into a spec. Trims whitespace; preserves locale identifier case.
  public static func parse(_ raw: String) throws -> LocaleSpec {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw LocaleSpecError.empty
    }
    if trimmed == "auto" { return .autoDefault }
    if trimmed.hasPrefix("auto:") {
      let suffix = String(trimmed.dropFirst("auto:".count))
        .trimmingCharacters(in: .whitespaces)
      if suffix == "*" || suffix == "any" { return .autoAny }
      let parts = suffix
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !parts.isEmpty else {
        throw LocaleSpecError.emptyCandidateList(raw: trimmed)
      }
      return .autoList(parts)
    }
    return .pin(trimmed)
  }
}

public enum LocaleSpecError: Error, CustomStringConvertible {
  case empty
  case emptyCandidateList(raw: String)

  public var description: String {
    switch self {
    case .empty: return "--locale value is empty"
    case .emptyCandidateList(let raw):
      return "--locale value '\(raw)' has no candidate locales after 'auto:'"
    }
  }
}

/// Hysteresis knobs from ADR-0003 §Configuration surface.
public struct LocaleHysteresisConfig: Equatable, Sendable {
  public var minFinals: Int
  public var confidence: Double
  public var cooldownSeconds: Double
  public var minChars: Int

  public static let `default` = LocaleHysteresisConfig(
    minFinals: 3,
    confidence: 0.70,
    cooldownSeconds: 30.0,
    minChars: 30
  )

  public init(
    minFinals: Int = 3,
    confidence: Double = 0.70,
    cooldownSeconds: Double = 30.0,
    minChars: Int = 30
  ) {
    self.minFinals = minFinals
    self.confidence = confidence
    self.cooldownSeconds = cooldownSeconds
    self.minChars = minChars
  }
}

/// Decision emitted by the resolver after a single final.
public enum LocaleResolverDecision: Equatable, Sendable {
  /// Nothing to do; resolver is pinned or no candidate gates passed.
  case stay
  /// Resolver wants to switch the live transcriber to `to` (an exact identifier from the candidate set).
  case switchTo(to: String, from: String, confidence: Double, charsAtCandidate: Int)
  /// Hysteresis suppressed a candidate; emitted as observability only.
  case suppressed(candidate: String, reason: SuppressReason)

  public enum SuppressReason: Equatable, Sendable {
    case belowConfidence(observed: Double)
    case belowMinFinals(observed: Int)
    case belowMinChars(observed: Int)
    case cooldown(elapsedSeconds: Double)
    case notInCandidateSet
    case sameAsCurrent
  }
}

/// Detector abstraction so tests can inject deterministic outputs.
public protocol LocaleLanguageDetector: Sendable {
  /// Return (bcp47Identifier, confidence) for the most-likely candidate from `candidates`.
  /// `confidence` should be in [0.0, 1.0]. `nil` means no detection.
  func detect(text: String, candidates: [String]) -> (locale: String, confidence: Double)?
}

/// Production detector backed by `NLLanguageRecognizer` with explicit
/// `languageConstraints` so candidates outside the configured set cannot
/// surface as winners.
public struct NLLanguageDetector: LocaleLanguageDetector {
  public init() {}

  public func detect(text: String, candidates: [String]) -> (locale: String, confidence: Double)? {
    guard !text.isEmpty else { return nil }
    let recognizer = NLLanguageRecognizer()
    if !candidates.isEmpty {
      let constraints = candidates.map { Self.nlLanguage(for: $0) }
      recognizer.languageConstraints = constraints
    }
    recognizer.processString(text)
    let maxHyp = max(candidates.count, 5)
    let hypotheses = recognizer.languageHypotheses(withMaximum: maxHyp)
    guard !hypotheses.isEmpty else { return nil }
    let best: (key: NLLanguage, value: Double)?
    if candidates.isEmpty {
      best = hypotheses.max { $0.value < $1.value }
    } else {
      let allowed = Set(candidates.map { Self.nlLanguage(for: $0).rawValue })
      best = hypotheses
        .filter { allowed.contains($0.key.rawValue) }
        .max { $0.value < $1.value }
    }
    guard let best else { return nil }
    let resolved: String
    if candidates.isEmpty {
      resolved = best.key.rawValue
    } else {
      resolved = Self.candidateMatching(language: best.key, in: candidates) ?? best.key.rawValue
    }
    return (locale: resolved, confidence: best.value)
  }

  /// Map a BCP-47 identifier ("pt-BR") onto an `NLLanguage` that the recognizer can
  /// constrain. Region tags are stripped; we keep regional identifiers in the
  /// candidate list separately so the resolver can pick the operator's preferred
  /// regional variant (`pt-BR`) even when the underlying recognizer only carries
  /// `.portuguese`.
  static func nlLanguage(for identifier: String) -> NLLanguage {
    let lang = identifier.split(separator: "-").first.map(String.init) ?? identifier
    return NLLanguage(rawValue: lang)
  }

  static func candidateMatching(language: NLLanguage, in candidates: [String]) -> String? {
    let raw = language.rawValue
    if let exact = candidates.first(where: { $0 == raw }) {
      return exact
    }
    return candidates.first {
      $0.split(separator: "-").first.map(String.init) == raw
    }
  }
}

/// Pure state machine implementing ADR-0003 candidate-set restriction +
/// 4-knob hysteresis. Lives in `Core/Speech` so subcommands can compose it.
///
/// Lifecycle:
/// * Initialise with `currentLocale`, the candidate set, the hysteresis knobs,
///   and a clock.
/// * Subcommands feed each final via `consider(final:)`.
/// * The resolver returns a `LocaleResolverDecision`. Subcommands act on
///   `.switchTo`, emit trace events for `.suppressed` / `.stay` (only when
///   useful), and finally update `currentLocale` to the announced target.
public struct LocaleResolver: Sendable {
  public private(set) var currentLocale: String
  public let candidateSet: [String]
  public let allowAny: Bool
  public let hysteresis: LocaleHysteresisConfig
  private let detector: LocaleLanguageDetector
  private var consecutive: ConsecutiveTracker
  private var lastSwitchAt: TimeInterval?
  private let now: @Sendable () -> TimeInterval

  /// Number of finals consumed by this resolver (for diagnostics).
  public private(set) var finalsConsidered: Int = 0
  /// Number of accepted switches.
  public private(set) var switchesAccepted: Int = 0

  public init(
    currentLocale: String,
    candidateSet: [String],
    allowAny: Bool = false,
    hysteresis: LocaleHysteresisConfig = .default,
    detector: LocaleLanguageDetector = NLLanguageDetector(),
    now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
  ) {
    self.currentLocale = currentLocale
    self.candidateSet = candidateSet
    self.allowAny = allowAny
    self.hysteresis = hysteresis
    self.detector = detector
    self.consecutive = ConsecutiveTracker()
    self.now = now
  }

  /// Feed one final and ask whether to switch. Pinned mode (empty candidate
  /// set, not auto-any) returns `.stay` for everything.
  public mutating func consider(final: String) -> LocaleResolverDecision {
    finalsConsidered += 1
    guard !candidateSet.isEmpty || allowAny else { return .stay }

    let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .stay }

    let candidates = allowAny ? [] : candidateSet
    guard let prediction = detector.detect(text: trimmed, candidates: candidates) else {
      consecutive.reset()
      return .stay
    }

    if !allowAny, !candidateSet.contains(prediction.locale) {
      consecutive.reset()
      return .suppressed(candidate: prediction.locale, reason: .notInCandidateSet)
    }

    if prediction.locale == currentLocale {
      consecutive.reset()
      return .suppressed(candidate: prediction.locale, reason: .sameAsCurrent)
    }

    if prediction.confidence < hysteresis.confidence {
      consecutive.reset()
      return .suppressed(candidate: prediction.locale, reason: .belowConfidence(observed: prediction.confidence))
    }

    consecutive.record(locale: prediction.locale, chars: trimmed.count)

    if consecutive.runLength < hysteresis.minFinals {
      return .suppressed(candidate: prediction.locale, reason: .belowMinFinals(observed: consecutive.runLength))
    }

    if consecutive.runChars < hysteresis.minChars {
      return .suppressed(candidate: prediction.locale, reason: .belowMinChars(observed: consecutive.runChars))
    }

    if let lastSwitchAt {
      let elapsed = now() - lastSwitchAt
      if elapsed < hysteresis.cooldownSeconds {
        return .suppressed(candidate: prediction.locale, reason: .cooldown(elapsedSeconds: elapsed))
      }
    }

    let decision = LocaleResolverDecision.switchTo(
      to: prediction.locale,
      from: currentLocale,
      confidence: prediction.confidence,
      charsAtCandidate: consecutive.runChars
    )
    currentLocale = prediction.locale
    lastSwitchAt = now()
    switchesAccepted += 1
    consecutive.reset()
    return decision
  }

  // MARK: - Private state

  private struct ConsecutiveTracker {
    var locale: String?
    var runLength: Int = 0
    var runChars: Int = 0

    mutating func record(locale: String, chars: Int) {
      if self.locale == locale {
        runLength += 1
        runChars += chars
      } else {
        self.locale = locale
        runLength = 1
        runChars = chars
      }
    }

    mutating func reset() {
      locale = nil
      runLength = 0
      runChars = 0
    }
  }
}

// MARK: - Operator-facing safe set (config file)

public struct LocaleSafeSet: Codable, Equatable, Sendable {
  public var safeSet: [String]

  public init(safeSet: [String]) {
    self.safeSet = safeSet
  }
}

public enum LocaleSafeSetLoader {
  public static let defaultSafeSet: [String] = ["en-US", "pt-BR"]

  /// Read `~/.config/chronicle/locales.json` when present. Missing/empty file
  /// → returns the built-in default. Malformed JSON throws so the daemon
  /// fails loudly rather than silently falling back.
  public static func load(at url: URL? = nil) throws -> [String] {
    let resolved = url ?? defaultURL()
    guard FileManager.default.fileExists(atPath: resolved.path) else {
      return defaultSafeSet
    }
    let data = try Data(contentsOf: resolved)
    if data.isEmpty { return defaultSafeSet }
    let decoded = try JSONDecoder().decode(LocaleSafeSet.self, from: data)
    if decoded.safeSet.isEmpty { return defaultSafeSet }
    return decoded.safeSet
  }

  public static func defaultURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("chronicle", isDirectory: true)
      .appendingPathComponent("locales.json", isDirectory: false)
  }
}

/// Validate that no two candidates share the same base language, since
/// `NLLanguageRecognizer` detects written language not regional variants.
/// For example, `["pt-BR", "pt-PT"]` is ambiguous — the recognizer returns
/// `.portuguese` for both and the resolver would always pick the first match.
public enum LocaleCandidateValidation {
  public static func rejectAmbiguousBaseLanguages(_ candidates: [String]) throws {
    let grouped = Dictionary(grouping: candidates) {
      $0.split(separator: "-").first.map(String.init) ?? $0
    }
    for (base, variants) in grouped where variants.count > 1 {
      throw LocaleCandidateError.ambiguousBaseLanguage(base: base, candidates: variants)
    }
  }
}

public enum LocaleCandidateError: Error, CustomStringConvertible {
  case ambiguousBaseLanguage(base: String, candidates: [String])

  public var description: String {
    switch self {
    case let .ambiguousBaseLanguage(base, candidates):
      return "--locale auto candidate set contains multiple '\(base)' regional variants: \(candidates.joined(separator: ", ")). NLLanguageRecognizer cannot distinguish regions; keep one variant per base language."
    }
  }
}
