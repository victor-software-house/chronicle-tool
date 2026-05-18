import AVFoundation
import Foundation

/// Collects ~N seconds of PCM audio from an `AudioSource` for the startup
/// language detection probe, then runs `AudioLanguageDetector.detect()`.
///
/// Used by both `mic` and `sysaudio` when `--locale auto` is active.
/// The probe buffers audio from `pcmBuffers`, converts to 16 kHz mono
/// Float (the format WhisperKit expects), and returns the detected
/// language code filtered to the candidate set.
@available(macOS 26.0, *)
public enum AudioLanguageProbe {
  /// Default probe duration in seconds. 3s is sufficient for reliable
  /// detection even on the `base` model per ADR-0006 experiments.
  public static let defaultProbeDurationSeconds: Double = 3.0

  /// Buffer audio from `source.pcmBuffers` for `duration` seconds, then
  /// run language detection. Returns the detected language code (e.g. "en",
  /// "pt") or nil if detection failed or no audio was captured.
  ///
  /// The probe consumes from `pcmBuffers` directly — if a `BufferMulticast`
  /// is active, subscribe a dedicated stream for the probe.
  public static func detect(
    source: any AudioSource,
    detector: AudioLanguageDetector,
    candidates: Set<String>? = nil,
    durationSeconds: Double = defaultProbeDurationSeconds,
    logTag: String = "locale"
  ) async throws -> (language: String, confidence: Double)? {
    // Collect PCM buffers for the probe duration.
    let analyzerFormat = source.analyzerFormat
    let targetSamples = Int(analyzerFormat.sampleRate * durationSeconds)
    var collected = [Float]()
    collected.reserveCapacity(targetSamples)

    let deadline = ContinuousClock.now + .seconds(durationSeconds + 2.0) // +2s grace
    for await ref in source.pcmBuffers {
      let buffer = ref.buffer
      // Extract Float samples. The analyzer format is typically 16kHz mono Int16.
      if let int16Data = buffer.int16ChannelData {
        let count = Int(buffer.frameLength)
        let ptr = int16Data[0]
        let scale: Float = 1.0 / 32_768.0
        for i in 0..<count {
          collected.append(Float(ptr[i]) * scale)
        }
      } else if let floatData = buffer.floatChannelData {
        let count = Int(buffer.frameLength)
        let ptr = floatData[0]
        for i in 0..<count {
          collected.append(ptr[i])
        }
      }
      if collected.count >= targetSamples { break }
      if ContinuousClock.now > deadline { break }
    }

    guard !collected.isEmpty else {
      FileHandle.standardError.write(Data(
        "[\(logTag).audio-detect] probe collected 0 samples; skipping detection\n".utf8
      ))
      return nil
    }

    let sampleRate = analyzerFormat.sampleRate
    FileHandle.standardError.write(Data(
      "[\(logTag).audio-detect] probe collected \(collected.count) samples (\(String(format: "%.1f", Double(collected.count) / sampleRate))s at \(Int(sampleRate)) Hz)\n".utf8
    ))

    // Resample to 16kHz if needed (WhisperKit expects 16kHz).
    let samples: [Float]
    if abs(sampleRate - 16_000) < 1.0 {
      samples = collected
    } else {
      // Simple linear resampling — good enough for language detection.
      let ratio = 16_000.0 / sampleRate
      let outCount = Int(Double(collected.count) * ratio)
      var resampled = [Float](repeating: 0, count: outCount)
      for i in 0..<outCount {
        let srcIdx = Double(i) / ratio
        let lo = Int(srcIdx)
        let hi = min(lo + 1, collected.count - 1)
        let frac = Float(srcIdx - Double(lo))
        resampled[i] = collected[lo] * (1 - frac) + collected[hi] * frac
      }
      samples = resampled
    }

    return try await detector.detect(audioSamples: samples, candidates: candidates)
  }
}
