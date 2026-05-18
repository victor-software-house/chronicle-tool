import Foundation
import WhisperKit

/// Audio-level language detector backed by WhisperKit.
///
/// Operates on raw 16 kHz mono `[Float]` audio samples — no transcription
/// text is involved. Uses the Whisper encoder + decoder to predict a language
/// token directly from the mel-spectrogram. Immune to the chicken-and-egg
/// failure in text-based detection (ADR-0006).
///
/// Candidate filtering: WhisperKit returns probabilities for all 99 Whisper
/// languages. This detector filters to the caller's candidate set (defaulting
/// to the system's preferred languages via `Locale.preferredLanguages`) and
/// returns the highest-scoring candidate.
///
/// Thread safety: callers must serialize calls to `load()` and `detect()`.
/// In practice the subcommand's main task owns this instance and calls are
/// naturally sequential.
public final class AudioLanguageDetector: @unchecked Sendable {
  /// WhisperKit model variant used for detection. `base` recommended per
  /// ADR-0006 experiment results (~150 MB, ~270 ms detection, best
  /// multilingual confidence calibration).
  public static let defaultModel = "base"

  private var kit: WhisperKit?
  private let modelName: String
  private let verbose: Bool

  public init(model: String = AudioLanguageDetector.defaultModel, verbose: Bool = false) {
    self.modelName = model
    self.verbose = verbose
  }

  /// Load the WhisperKit model. Call once during startup. Logs progress.
  /// Downloads model assets on first use (~150 MB for base).
  public func load() async throws {
    guard kit == nil else { return }
    if verbose {
      FileHandle.standardError.write(Data(
        "[locale.audio-detect] loading WhisperKit model=\(modelName)...\n".utf8
      ))
    }
    let config = WhisperKitConfig(model: modelName, verbose: false, logLevel: .error)
    let loaded = try await WhisperKit(config)
    kit = loaded
    if verbose {
      FileHandle.standardError.write(Data(
        "[locale.audio-detect] model loaded\n".utf8
      ))
    }
  }

  /// Detect language from raw 16 kHz mono Float audio samples.
  ///
  /// - Parameters:
  ///   - audioSamples: PCM Float32 samples at 16 kHz mono.
  ///   - candidates: BCP-47 base language codes to filter to (e.g. `{"en", "pt"}`).
  ///     Defaults to system preferred languages if nil.
  /// - Returns: `(language, confidence)` where confidence is negative log-likelihood
  ///   (closer to 0 = more confident). Returns nil if no candidate matches.
  public func detect(
    audioSamples: [Float],
    candidates: Set<String>? = nil
  ) async throws -> (language: String, confidence: Double)? {
    guard let kit else {
      throw AudioLanguageDetectorError.modelNotLoaded
    }
    let effectiveCandidates = candidates ?? Self.systemPreferredLanguages()
    guard !effectiveCandidates.isEmpty else {
      throw AudioLanguageDetectorError.noCandidates
    }

    let (_, probs) = try await kit.detectLangauge(audioArray: audioSamples)

    // Filter to candidate set and pick the best.
    let best = probs
      .filter { effectiveCandidates.contains($0.key) }
      .max(by: { $0.value < $1.value })

    guard let best else { return nil }

    if verbose {
      let top3 = probs.sorted { $0.value > $1.value }.prefix(3)
        .map { "\($0.key)=\(String(format: "%.4f", $0.value))" }
        .joined(separator: ", ")
      FileHandle.standardError.write(Data(
        "[locale.audio-detect] detected=\(best.key) confidence=\(String(format: "%.4f", best.value)) candidates=\(effectiveCandidates.sorted().joined(separator: ",")) top3=[\(top3)]\n".utf8
      ))
    }

    return (language: best.key, confidence: Double(best.value))
  }

  /// Extract base language codes from system preferred languages.
  /// E.g. `["en-BR", "pt-BR"]` → `{"en", "pt"}`.
  public static func systemPreferredLanguages() -> Set<String> {
    Set(
      Locale.preferredLanguages.compactMap {
        Locale(identifier: $0).language.languageCode?.identifier
      }
    )
  }
}

public enum AudioLanguageDetectorError: Error, CustomStringConvertible {
  case modelNotLoaded
  case noCandidates

  public var description: String {
    switch self {
    case .modelNotLoaded:
      return "AudioLanguageDetector: WhisperKit model not loaded. Call load() first."
    case .noCandidates:
      return "AudioLanguageDetector: no candidate languages provided and Locale.preferredLanguages is empty."
    }
  }
}
