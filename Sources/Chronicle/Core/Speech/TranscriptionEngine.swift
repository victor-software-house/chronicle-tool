import AVFoundation
import Foundation
import Speech

/// Resolved configuration + handles for one `SpeechAnalyzer` session backed
/// by a single `SpeechTranscriber` module.
///
/// `TranscriptionEngine.make(locale:preset:tag:)` performs the standard
/// boilerplate every subcommand needs:
///
/// 1. Resolves the requested locale via `SpeechTranscriber.supportedLocale`.
/// 2. Constructs the `SpeechTranscriber` at the requested preset.
/// 3. Installs the on-device model assets via `AssetInventory` if missing.
/// 4. Resolves the analyzer's preferred audio format
///    (`SpeechAnalyzer.bestAvailableAudioFormat`) — used by live subcommands
///    to configure their `AudioSource`.
/// 5. Constructs the `SpeechAnalyzer(modules:)`.
///
/// The returned value owns nothing exclusively; the caller is responsible
/// for finalising or cancelling the analyzer.
@available(macOS 26.0, *)
public struct TranscriptionEngine: Sendable {
  public let locale: Locale
  public let preset: SpeechTranscriber.Preset
  public let transcriber: SpeechTranscriber
  public let analyzer: SpeechAnalyzer
  public let analyzerFormat: AVAudioFormat?

  /// Build a `SpeechTranscriber` + `SpeechAnalyzer` pair for the requested
  /// locale + preset. Installs model assets on first use. Resolves the
  /// analyzer's preferred audio format eagerly so live sources have it.
  ///
  /// - Parameters:
  ///   - locale: requested locale; falls back to the closest supported locale.
  ///   - preset: which preset the transcriber should run at.
  ///   - tag: short prefix for log lines (`mic`, `live`, `transcribe`).
  public static func make(
    locale requested: Locale,
    preset: SpeechTranscriber.Preset,
    tag: String
  ) async throws -> TranscriptionEngine {
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
      throw TranscriptionEngineError.unsupportedLocale(requested)
    }

    let transcriber = SpeechTranscriber(locale: supported, preset: preset)

    if !(await SpeechTranscriber.installedLocales).contains(supported) {
      FileHandle.standardError.write(Data("[\(tag)] downloading model for \(supported.identifier)...\n".utf8))
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }
    }

    FileHandle.standardError.write(Data("[\(tag)] locale=\(supported.identifier) preset=\(presetName(preset))\n".utf8))

    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    return TranscriptionEngine(
      locale: supported,
      preset: preset,
      transcriber: transcriber,
      analyzer: analyzer,
      analyzerFormat: analyzerFormat
    )
  }

  /// Stable string for the preset used in receipts and trace events.
  public static func presetName(_ preset: SpeechTranscriber.Preset) -> String {
    switch preset {
    case .progressiveTranscription: return "progressiveTranscription"
    case .transcription: return "transcription"
    default: return String(describing: preset)
    }
  }
}

public enum TranscriptionEngineError: Error, CustomStringConvertible {
  case unsupportedLocale(Locale)

  public var description: String {
    switch self {
    case .unsupportedLocale(let loc):
      return "Locale \(loc.identifier) is not supported by SpeechTranscriber. Try DictationTranscriber."
    }
  }
}
