import Foundation
import FoundationModels

/// Guided-generation summary produced by `Summarizer`. Top-level type so any
/// subcommand or downstream consumer can decode the same shape.
@Generable
public struct ChronicleSummary: Sendable {
  @Guide(description: "One-sentence high-level summary of the content.")
  public var tldr: String
  @Guide(description: "Short bullet list of the key points.")
  public var bullets: [String]
  @Guide(description: "Concrete decisions reached or claims made.")
  public var decisions: [String]
  @Guide(description: "Action items, follow-ups, or open questions.")
  public var actionItems: [String]
}

/// Summarise arbitrary text via the Foundation Models default model.
/// Callable from the `summarize` subcommand and any downstream consumer.
public enum Summarizer {
  /// Summarise `text` into a tl;dr + bullets + decisions + action items.
  /// Aims for at most `bullets` bullets; truncates input to 30,000
  /// characters to keep the prompt bounded.
  public static func summarizeText(_ text: String, bullets: Int = 8) async throws -> ChronicleSummary {
    let session = try await ModelHost.shared.session(
      for: .default,
      instructions: """
        You summarize transcripts of meetings, calls, and presentations.
        Be faithful: do not invent facts the text does not state.
        Prefer concrete nouns; avoid vague hedges.
        """
    )
    let prompt = """
      Produce a structured summary of the following text.
      Aim for at most \(bullets) bullets.
      Text:
      ---
      \(text.prefix(30_000))
      ---
      """
    let response = try await session.respond(to: prompt, generating: ChronicleSummary.self)
    return response.content
  }
}
