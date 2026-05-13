import Foundation
import FoundationModels

/// Cached `LanguageModelSession` factory.
///
/// Apple's `LanguageModelSession` carries a non-trivial prewarm cost on the
/// first call (~hundreds of ms). Tag, Summarize, Describe, and the live
/// tagger (FR-5) all want sessions; without caching every short call eats
/// the prewarm again. `ModelHost` caches sessions by a stable key so the
/// cost is paid once per process.
///
/// Use:
///
///     let session = try await ModelHost.shared.session(
///       for: .contentTagging,
///       instructions: nil
///     )
///     let response = try await session.respond(to: prompt, generating: T.self)
public actor ModelHost {
  public static let shared = ModelHost()

  private var sessions: [SessionKey: LanguageModelSession] = [:]

  /// Composite key for the session cache. `useCase` discriminates between
  /// `SystemLanguageModel.default` (key: "default") and
  /// `SystemLanguageModel(useCase: .contentTagging)` etc. `instructions`
  /// further discriminates by the system prompt, since two consumers of the
  /// same model may need different instructions.
  private struct SessionKey: Hashable, Sendable {
    let useCase: String
    let instructions: String?
  }

  /// Slim view over `SystemLanguageModel.UseCase` so `ModelHost` doesn't
  /// leak Apple's nested type into every call site.
  public enum UseCase: Sendable, Hashable {
    case `default`
    case contentTagging
    case other(String)

    var key: String {
      switch self {
      case .default: return "default"
      case .contentTagging: return "contentTagging"
      case .other(let s): return "other:\(s)"
      }
    }

    fileprivate func resolveModel() -> SystemLanguageModel {
      switch self {
      case .default: return SystemLanguageModel.default
      case .contentTagging: return SystemLanguageModel(useCase: .contentTagging)
      case .other: return SystemLanguageModel.default
      }
    }
  }

  /// Validate the model is currently available and return a cached
  /// `LanguageModelSession` for the requested use-case + instructions.
  /// Subsequent calls with the same key skip the prewarm cost.
  ///
  /// Throws `ModelHostError.unavailable` with a friendly reason when Apple
  /// Intelligence is disabled, the device is ineligible, or the model is
  /// not yet downloaded.
  public func session(
    for useCase: UseCase = .default,
    instructions: String? = nil
  ) throws -> LanguageModelSession {
    let key = SessionKey(useCase: useCase.key, instructions: instructions)
    if let cached = sessions[key] { return cached }

    let model = useCase.resolveModel()
    switch model.availability {
    case .available:
      break
    case .unavailable(let reason):
      throw ModelHostError.unavailable(reason)
    @unknown default:
      throw ModelHostError.unavailable(.modelNotReady)
    }

    let session: LanguageModelSession
    if let instructions {
      session = LanguageModelSession(model: model, instructions: instructions)
    } else {
      session = LanguageModelSession(model: model)
    }
    sessions[key] = session
    return session
  }
}

public enum ModelHostError: Error, CustomStringConvertible {
  case unavailable(SystemLanguageModel.Availability.UnavailableReason)

  public var description: String {
    switch self {
    case .unavailable(let reason):
      return "Foundation Models unavailable: \(reason)"
    }
  }

  /// Human-readable remediation hint for stderr.
  public var remediation: String {
    switch self {
    case .unavailable(.appleIntelligenceNotEnabled):
      return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri."
    case .unavailable(.deviceNotEligible):
      return "This Mac is not eligible for Apple Intelligence."
    case .unavailable(.modelNotReady):
      return "Model not yet downloaded; try again shortly."
    case .unavailable:
      return ""
    }
  }
}
