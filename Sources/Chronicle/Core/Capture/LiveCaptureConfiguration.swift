import Foundation

public struct LiveCaptureConfiguration: Codable, Equatable, Sendable {
  public let source: CaptureSource
  public let locale: String?
  public let tracePath: String?
  public let finalsPath: String?
  public let livePath: String?
  public let audioPath: String?
  public let audioFormat: String
  public let diarizationEnabled: Bool
  public let rotateAudioSeconds: Double

  public static func direct(
    source: CaptureSource,
    locale: String?,
    output: String?,
    append: String?,
    live: String?,
    saveAudio: String?,
    audioFormat: String,
    diarize: Bool,
    rotateAudio: Double = 60.0
  ) -> LiveCaptureConfiguration {
    LiveCaptureConfiguration(
      source: source,
      locale: locale,
      tracePath: output,
      finalsPath: append,
      livePath: live,
      audioPath: saveAudio,
      audioFormat: audioFormat,
      diarizationEnabled: diarize,
      rotateAudioSeconds: rotateAudio
    )
  }

  public func policy(for change: LiveCaptureChange, whileActive: Bool) -> LiveCaptureChangeDecision {
    guard whileActive else { return .applyBeforeStart }

    switch change {
    case .setDiarization:
      return .applyLive(reason: "progressive layer change keeps rough transcript active")
    case .setRotateAudio:
      return .futureSegment(reason: "rotation changes apply when the next audio segment opens")
    case .setLocale:
      return .futureSegment(reason: "locale changes apply to future transcription segments")
    case .setAudioFormat:
      return .reject(
        reason: "audio sidecar format cannot change safely while capture is active",
        alternative: "Keep rough transcript running and start a new segment or restart capture with the new audio format."
      )
    case .setTracePath, .setFinalsPath, .setLivePath, .setAudioPath:
      return .reject(
        reason: "sidecar writer paths cannot change safely while capture is active",
        alternative: "Start a new segment with the requested output paths."
      )
    }
  }
}

public enum LiveCaptureChange: Codable, Equatable, Sendable {
  case setDiarization(enabled: Bool)
  case setLocale(String)
  case setAudioFormat(String)
  case setRotateAudio(seconds: Double)
  case setTracePath(String)
  case setFinalsPath(String)
  case setLivePath(String)
  case setAudioPath(String)
}

public enum LiveCaptureChangeDecision: Codable, Equatable, Sendable {
  case applyBeforeStart
  case applyLive(reason: String)
  case futureSegment(reason: String)
  case reject(reason: String, alternative: String)
}
