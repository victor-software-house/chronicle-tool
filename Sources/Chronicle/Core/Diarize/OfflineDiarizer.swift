import Foundation
import FluidAudio

/// Offline speaker diarization via FluidAudio's VBx pipeline (CoreML, Neural
/// Engine). Apple ships no diarization API on macOS 26; FluidAudio is the
/// production-quality option for "who spoke when".
///
/// Models are downloaded into the user's caches on first run; subsequent
/// instantiations reuse them.
public final class OfflineDiarizer: OfflineDiarizing, @unchecked Sendable {
  private var manager: DiarizerManager?
  private var models: DiarizerModels?
  private let converter = AudioConverter()
  private let logTag: String

  /// `logTag` is the bracketed prefix (e.g. `diarize`) used on stderr lines.
  public init(logTag: String = "diarize") {
    self.logTag = logTag
  }

  /// Download or load models on first call; reuses the manager on subsequent
  /// calls so a long-running daemon pays the load cost once.
  private func ensureLoaded() async throws {
    if manager != nil { return }
    FileHandle.standardError.write(Data("[\(logTag)] downloading or loading FluidAudio diarizer models...\n".utf8))
    let m = try await DiarizerModels.downloadIfNeeded()
    let mgr = DiarizerManager()
    mgr.initialize(models: m)
    self.models = m
    self.manager = mgr
    FileHandle.standardError.write(Data("[\(logTag)] models ready\n".utf8))
  }

  public func diarizeFile(_ url: URL) async throws -> DiarizationResult {
    try await ensureLoaded()
    guard let mgr = manager else {
      throw OfflineDiarizerError.notInitialised
    }

    let samples = try converter.resampleAudioFile(url)
    let sampleCount = samples.count
    let durationSec = Double(sampleCount) / 16_000.0
    FileHandle.standardError.write(Data(
      "[\(logTag)] audio=\(String(format: "%.2f", durationSec))s samples=\(sampleCount) @ 16kHz mono float32\n".utf8
    ))

    let started = Date()
    let result = try await mgr.performCompleteDiarization(samples)
    let elapsed = Date().timeIntervalSince(started)

    let segments = result.segments.map { seg in
      DiarizationSegment(
        speakerId: seg.speakerId,
        startSeconds: Double(seg.startTimeSeconds),
        endSeconds: Double(seg.endTimeSeconds)
      )
    }

    return DiarizationResult(
      segments: segments,
      audioDurationSeconds: durationSec,
      elapsedSeconds: elapsed
    )
  }
}

public enum OfflineDiarizerError: Error, CustomStringConvertible {
  case notInitialised

  public var description: String {
    switch self {
    case .notInitialised: return "OfflineDiarizer was not initialised before diarizeFile()."
    }
  }
}
