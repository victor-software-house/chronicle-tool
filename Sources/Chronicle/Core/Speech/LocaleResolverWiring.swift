import Foundation

extension Locale {
  /// Apple's `Locale.identifier` returns Unicode-locale form with underscores
  /// (`en_US`); the resolver's candidate sets and NLLanguageRecognizer
  /// constraints use BCP-47 (`en-US`). This helper normalises the live
  /// transcriber's locale into the BCP-47 form so identifier comparisons in
  /// `LocaleResolver.consider` are not mismatched by separator style.
  public var bcp47Identifier: String {
    if #available(macOS 13, *) {
      return identifier(.bcp47)
    }
    return identifier.replacingOccurrences(of: "_", with: "-")
  }
}

extension LocaleSpec {
  /// Initial locale to start the transcriber at. For pin, the literal value;
  /// for auto modes, the first candidate in the resolved candidate set (or the
  /// caller-supplied default when the safe set is empty).
  public func initialLocaleIdentifier(default fallback: String) -> String {
    switch self {
    case .pin(let id):
      return id
    case .autoDefault:
      let set = (try? LocaleSafeSetLoader.load()) ?? LocaleSafeSetLoader.defaultSafeSet
      return set.first ?? fallback
    case .autoList(let set):
      return set.first ?? fallback
    case .autoAny:
      return fallback
    }
  }

  /// Build a `LocaleResolver` for live auto-detect. Returns `nil` when the
  /// spec is a pin, in which case live subcommands run without detection.
  public func makeResolver(
    currentLocale: String,
    hysteresis: LocaleHysteresisConfig = .default,
    detector: LocaleLanguageDetector = NLLanguageDetector(),
    safeSetURL: URL? = nil
  ) -> LocaleResolver? {
    switch self {
    case .pin:
      return nil
    case .autoDefault:
      let set = (try? LocaleSafeSetLoader.load(at: safeSetURL)) ?? LocaleSafeSetLoader.defaultSafeSet
      return LocaleResolver(
        currentLocale: currentLocale,
        candidateSet: set,
        allowAny: false,
        hysteresis: hysteresis,
        detector: detector
      )
    case .autoList(let set):
      return LocaleResolver(
        currentLocale: currentLocale,
        candidateSet: set,
        allowAny: false,
        hysteresis: hysteresis,
        detector: detector
      )
    case .autoAny:
      return LocaleResolver(
        currentLocale: currentLocale,
        candidateSet: [],
        allowAny: true,
        hysteresis: hysteresis,
        detector: detector
      )
    }
  }
}

/// Helper that reports `LocaleResolverDecision` events to operator stderr and
/// the JSONL trace sink. Suppression events are stderr-only by default to
/// avoid filling the trace with low-signal lines; accepted switches are also
/// written as `control` events so `chronicle merge` (and any future
/// consumer) can see exactly when the daemon's detected locale changed.
///
/// Note: this helper records the resolver's *decision*. Until the live
/// SpeechAnalyzer restart path lands, the active transcriber stays at the
/// initial locale even after `switchTo` is recorded; the decision is the
/// observable signal.
public enum LocaleResolverWiring {
  public static func report(
    logTag: String,
    decision: LocaleResolverDecision,
    traceSink: JSONLTraceSink?,
    wallclockOffsetMs: Double,
    wallclock: Date
  ) async {
    switch decision {
    case .stay:
      return
    case let .switchTo(to, from, confidence, charsAtCandidate):
      let line = "[\(logTag).locale switchTo] to=\(to) from=\(from) confidence=\(String(format: "%.2f", confidence)) charsAtCandidate=\(charsAtCandidate)\n"
      FileHandle.standardError.write(Data(line.utf8))
      if let traceSink {
        let payload = controlPayload(
          decision: "switchTo",
          to: to,
          from: from,
          confidence: confidence,
          charsAtCandidate: charsAtCandidate
        )
        await traceSink.record(
          eventKind: .control,
          text: payload,
          monotonicOffsetMs: wallclockOffsetMs,
          wallclock: wallclock
        )
      }
    case let .suppressed(candidate, reason):
      let reasonText = describe(reason: reason)
      let line = "[\(logTag).locale suppressed] candidate=\(candidate) reason=\(reasonText)\n"
      FileHandle.standardError.write(Data(line.utf8))
    }
  }

  private static func describe(reason: LocaleResolverDecision.SuppressReason) -> String {
    switch reason {
    case .belowConfidence(let v): return "below-confidence(\(String(format: "%.2f", v)))"
    case .belowMinFinals(let v): return "below-min-finals(\(v))"
    case .belowMinChars(let v): return "below-min-chars(\(v))"
    case .cooldown(let v): return "cooldown(elapsed=\(String(format: "%.1f", v))s)"
    case .notInCandidateSet: return "not-in-candidate-set"
    case .sameAsCurrent: return "same-as-current"
    }
  }

  private static func controlPayload(
    decision: String,
    to: String,
    from: String,
    confidence: Double,
    charsAtCandidate: Int
  ) -> String {
    let dict: [String: Any] = [
      "kind": "locale",
      "decision": decision,
      "to": to,
      "from": from,
      "confidence": confidence,
      "charsAtCandidate": charsAtCandidate
    ]
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
      let str = String(data: data, encoding: .utf8)
    {
      return str
    }
    return "locale switchTo \(from) -> \(to)"
  }
}
