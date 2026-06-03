import Foundation
import Testing
@testable import ChronicleCore

/// Thread-safe shared mock clock so Sendable `now:` closures can advance time deterministically.
final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval
  init(initial: TimeInterval) { self.time = initial }
  var now: TimeInterval { lock.withLock { time } }
  func advance(by seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// Deterministic detector for hysteresis tests. The next detection is popped
/// from the FIFO queue; nil means "no detection on this final".
final class StubLocaleDetector: LocaleLanguageDetector, @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [(String, Double)?]

  init(_ outputs: [(String, Double)?]) {
    self.queue = outputs
  }

  func detect(text: String, candidates: [String]) -> (locale: String, confidence: Double)? {
    lock.withLock {
      guard !queue.isEmpty else { return nil }
      return queue.removeFirst().map { (locale: $0.0, confidence: $0.1) }
    }
  }
}

@Suite("LocaleResolver")
struct LocaleResolverTests {
  // MARK: - LocaleSpec parsing

  @Test("parses pin, auto, auto:list, auto:* / auto:any")
  func parsesFlagGrammar() throws {
    #expect(try LocaleSpec.parse("en-US") == .pin("en-US"))
    #expect(try LocaleSpec.parse(" en-US ") == .pin("en-US"))
    #expect(try LocaleSpec.parse("auto") == .autoDefault)
    #expect(try LocaleSpec.parse("auto:en-US,pt-BR") == .autoList(["en-US", "pt-BR"]))
    #expect(try LocaleSpec.parse("auto:*") == .autoAny)
    #expect(try LocaleSpec.parse("auto:any") == .autoAny)
  }

  @Test("rejects empty value and empty auto candidate list")
  func rejectsEmptyOrEmptyCandidateList() {
    #expect(throws: LocaleSpecError.self) {
      _ = try LocaleSpec.parse("")
    }
    #expect(throws: LocaleSpecError.self) {
      _ = try LocaleSpec.parse("auto:")
    }
    #expect(throws: LocaleSpecError.self) {
      _ = try LocaleSpec.parse("auto: , ,")
    }
  }

  // MARK: - State machine

  @Test("switches after N consecutive high-confidence finals on a candidate in the safe set")
  func switchesAfterHysteresis() {
    let detector = StubLocaleDetector([
      ("pt-BR", 0.9),
      ("pt-BR", 0.9),
      ("pt-BR", 0.9)
    ])
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: ["en-US", "pt-BR"],
      hysteresis: LocaleHysteresisConfig(minFinals: 3, confidence: 0.7, cooldownSeconds: 30, minChars: 10),
      detector: detector,
      now: { 1_000 }
    )

    #expect(resolver.consider(final: "Olá pessoal, vamos começar") == .suppressed(candidate: "pt-BR", reason: .belowMinFinals(observed: 1)))
    #expect(resolver.consider(final: "tudo certo aqui, obrigado") == .suppressed(candidate: "pt-BR", reason: .belowMinFinals(observed: 2)))
    let final = resolver.consider(final: "vamos para o próximo ponto")
    #expect(final == .switchTo(to: "pt-BR", from: "en-US", confidence: 0.9, charsAtCandidate: 77))
    #expect(resolver.currentLocale == "pt-BR")
    #expect(resolver.switchesAccepted == 1)
  }

  @Test("rejects out-of-set candidate even at high confidence")
  func rejectsOutOfSetCandidate() {
    let detector = StubLocaleDetector([
      ("ru", 0.99),
      ("ru", 0.99),
      ("ru", 0.99)
    ])
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: ["en-US", "pt-BR"],
      hysteresis: .default,
      detector: detector,
      now: { 1_000 }
    )

    for _ in 0..<3 {
      let decision = resolver.consider(final: "anything")
      #expect(decision == .suppressed(candidate: "ru", reason: .notInCandidateSet))
    }
    #expect(resolver.currentLocale == "en-US")
    #expect(resolver.switchesAccepted == 0)
  }

  @Test("suppresses switch below confidence threshold")
  func suppressesBelowConfidence() {
    let detector = StubLocaleDetector([
      ("pt-BR", 0.5),
      ("pt-BR", 0.5),
      ("pt-BR", 0.5)
    ])
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: ["en-US", "pt-BR"],
      hysteresis: LocaleHysteresisConfig(minFinals: 3, confidence: 0.7, cooldownSeconds: 30, minChars: 5),
      detector: detector,
      now: { 1_000 }
    )

    for _ in 0..<3 {
      let decision = resolver.consider(final: "olá")
      #expect(decision == .suppressed(candidate: "pt-BR", reason: .belowConfidence(observed: 0.5)))
    }
    #expect(resolver.switchesAccepted == 0)
  }

  @Test("suppresses switch when total chars at candidate are below the min")
  func suppressesBelowMinChars() {
    let detector = StubLocaleDetector([
      ("pt-BR", 0.9),
      ("pt-BR", 0.9),
      ("pt-BR", 0.9)
    ])
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: ["en-US", "pt-BR"],
      hysteresis: LocaleHysteresisConfig(minFinals: 3, confidence: 0.7, cooldownSeconds: 30, minChars: 100),
      detector: detector,
      now: { 1_000 }
    )

    _ = resolver.consider(final: "olá")
    _ = resolver.consider(final: "tudo")
    let decision = resolver.consider(final: "bem")
    if case .suppressed(_, .belowMinChars) = decision { } else {
      Issue.record("expected belowMinChars; got \(decision)")
    }
    #expect(resolver.switchesAccepted == 0)
  }

  @Test("suppresses second switch within the cooldown window")
  func suppressesWithinCooldown() {
    let detector = StubLocaleDetector([
      ("pt-BR", 0.9), ("pt-BR", 0.9), ("pt-BR", 0.9),
      ("en-US", 0.9), ("en-US", 0.9), ("en-US", 0.9),
      ("en-US", 0.9), ("en-US", 0.9), ("en-US", 0.9)
    ])
    let clock = MutableClock(initial: 1_000)
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: ["en-US", "pt-BR"],
      hysteresis: LocaleHysteresisConfig(minFinals: 3, confidence: 0.7, cooldownSeconds: 30, minChars: 5),
      detector: detector,
      now: { clock.now }
    )

    _ = resolver.consider(final: "olá tudo bem por aqui")
    _ = resolver.consider(final: "olá tudo bem por aqui")
    let firstSwitch = resolver.consider(final: "olá tudo bem por aqui")
    #expect(firstSwitch == .switchTo(to: "pt-BR", from: "en-US", confidence: 0.9, charsAtCandidate: 63))

    clock.advance(by: 5)
    _ = resolver.consider(final: "hello again from here")
    _ = resolver.consider(final: "hello again from here")
    let blocked = resolver.consider(final: "hello again from here")
    if case .suppressed(_, .cooldown) = blocked { } else {
      Issue.record("expected cooldown suppression; got \(blocked)")
    }
    #expect(resolver.currentLocale == "pt-BR")

    clock.advance(by: 100)
    let afterCooldown = resolver.consider(final: "hello again from here")
    if case let .switchTo(to, from, _, _) = afterCooldown {
      #expect(to == "en-US")
      #expect(from == "pt-BR")
    } else {
      Issue.record("expected switch back to en-US after cooldown; got \(afterCooldown)")
    }
    #expect(resolver.switchesAccepted == 2)
  }

  @Test("pin mode does not run detection")
  func pinModeBypassesDetection() {
    let detector = StubLocaleDetector([
      ("pt-BR", 0.99), ("pt-BR", 0.99), ("pt-BR", 0.99)
    ])
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: [],
      allowAny: false,
      hysteresis: .default,
      detector: detector,
      now: { 1_000 }
    )

    for _ in 0..<3 {
      #expect(resolver.consider(final: "anything") == .stay)
    }
    #expect(resolver.currentLocale == "en-US")
    #expect(resolver.switchesAccepted == 0)
  }

  @Test("single loanword run is broken by a non-matching final and never triggers")
  func nonConsecutiveLoanwordsNeverSwitch() {
    let detector = StubLocaleDetector([
      ("pt-BR", 0.9),
      nil,
      ("pt-BR", 0.9),
      nil,
      ("pt-BR", 0.9)
    ])
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: ["en-US", "pt-BR"],
      hysteresis: LocaleHysteresisConfig(minFinals: 3, confidence: 0.7, cooldownSeconds: 30, minChars: 5),
      detector: detector,
      now: { 1_000 }
    )

    var decisions: [LocaleResolverDecision] = []
    for _ in 0..<5 {
      decisions.append(resolver.consider(final: "café"))
    }
    #expect(resolver.switchesAccepted == 0)
    #expect(resolver.currentLocale == "en-US")
    // All non-nil detections should be suppressed because the streak keeps resetting.
    for d in decisions where d != .stay {
      if case .suppressed(_, .belowMinFinals) = d { continue }
      Issue.record("unexpected decision: \(d)")
    }
  }

  // MARK: - auto:* (unconstrained detection)

  @Test("auto:* mode detects language without candidate constraints")
  func autoAnyDetectsUnconstrained() {
    let detector = StubLocaleDetector([
      ("pt", 0.9),
      ("pt", 0.9),
      ("pt", 0.9)
    ])
    var resolver = LocaleResolver(
      currentLocale: "en-US",
      candidateSet: [],
      allowAny: true,
      hysteresis: LocaleHysteresisConfig(minFinals: 3, confidence: 0.7, cooldownSeconds: 30, minChars: 5),
      detector: detector,
      now: { 1_000 }
    )

    _ = resolver.consider(final: "Olá pessoal vamos começar")
    _ = resolver.consider(final: "tudo certo aqui obrigado")
    let decision = resolver.consider(final: "vamos para o próximo ponto")
    if case let .switchTo(to, _, _, _) = decision {
      #expect(to == "pt")
    } else {
      Issue.record("expected switchTo; got \(decision)")
    }
    #expect(resolver.switchesAccepted == 1)
  }

  // MARK: - Ambiguous base-language validation

  @Test("rejects candidate sets with duplicate base languages")
  func rejectsAmbiguousBaseLanguages() {
    #expect(throws: LocaleCandidateError.self) {
      try LocaleCandidateValidation.rejectAmbiguousBaseLanguages(["pt-BR", "pt-PT", "en-US"])
    }
  }

  @Test("accepts candidate sets with distinct base languages")
  func acceptsDistinctBaseLanguages() throws {
    try LocaleCandidateValidation.rejectAmbiguousBaseLanguages(["pt-BR", "en-US", "es-ES"])
  }

  // MARK: - Safe-set config

  @Test("LocaleSafeSetLoader returns built-in default when no file is present")
  func safeSetDefaults() throws {
    let url = URL(fileURLWithPath: "/tmp/chronicle-locales-nonexistent-\(UUID()).json")
    let loaded = try LocaleSafeSetLoader.load(at: url)
    #expect(loaded == LocaleSafeSetLoader.defaultSafeSet)
  }

  @Test("LocaleSafeSetLoader reads safeSet from JSON")
  func safeSetFromFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chronicle-locales-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("locales.json")
    let json = #"{"safeSet": ["pt-BR", "es-ES", "en-US"]}"#
    try json.write(to: url, atomically: true, encoding: .utf8)
    let loaded = try LocaleSafeSetLoader.load(at: url)
    #expect(loaded == ["pt-BR", "es-ES", "en-US"])
  }

  // MARK: - NLLanguageDetector smoke

  @Test("NLLanguageDetector picks pt-BR from constrained set on Portuguese sentence")
  func nlDetectorPicksPortuguese() {
    let detector = NLLanguageDetector()
    let result = detector.detect(
      text: "Olá pessoal, vamos começar a reunião de quinta-feira agora.",
      candidates: ["en-US", "pt-BR"]
    )
    #expect(result?.locale == "pt-BR")
    #expect((result?.confidence ?? 0) > 0.5)
  }

  @Test("Locale.bcp47Identifier normalises Apple identifier separator")
  func bcp47NormalisesUnderscore() {
    #expect(Locale(identifier: "en_US").bcp47Identifier == "en-US")
    #expect(Locale(identifier: "pt_BR").bcp47Identifier == "pt-BR")
    #expect(Locale(identifier: "en-US").bcp47Identifier == "en-US")
  }

  @Test("NLLanguageDetector picks en-US from constrained set on English sentence")
  func nlDetectorPicksEnglish() {
    let detector = NLLanguageDetector()
    let result = detector.detect(
      text: "Welcome to the quarterly business review meeting on Thursday morning.",
      candidates: ["en-US", "pt-BR"]
    )
    #expect(result?.locale == "en-US")
    #expect((result?.confidence ?? 0) > 0.5)
  }
}
