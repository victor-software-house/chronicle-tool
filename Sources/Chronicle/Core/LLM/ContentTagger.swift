import Foundation
import FoundationModels

/// Guided-generation tag set produced by `ContentTagger`. Top-level type so
/// any subcommand or live sink can decode the same shape.
@Generable
public struct ChronicleTagSet: Sendable {
  @Guide(description: "Topic tags identifying the subject matter of the text.")
  public var topics: [String]
  @Guide(description: "Named entities (people, products, organisations, places).")
  public var entities: [String]
  @Guide(description: "Actions or verbs that summarise what happened in the text.")
  public var actions: [String]
}

/// Tag arbitrary text via the Foundation Models content-tagging adapter.
/// Callable from `tag` subcommand and the FR-5 live tagger; both share the
/// same cached session through `ModelHost`.
public enum ContentTagger {
  /// Tag `text`, returning at most `limit` items per category.
  /// Truncates input to 20,000 characters to keep the prompt bounded.
  public static func tagText(_ text: String, limit: Int = 15) async throws -> ChronicleTagSet {
    let session = try await ModelHost.shared.session(for: .contentTagging)
    let prompt = """
      Tag the following text. Return at most \(limit) items per category.
      Be specific and concrete; prefer multi-word topics ("speech recognition" over "speech").
      Text:
      ---
      \(text.prefix(20_000))
      ---
      """
    let response = try await session.respond(to: prompt, generating: ChronicleTagSet.self)
    return response.content
  }
}
