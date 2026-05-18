import AVFoundation
import Foundation

/// Non-blocking audio language detection that runs concurrently with
/// transcription. Buffers PCM from a multicast subscription, waits for
/// speech energy, then runs WhisperKit `detectLanguage()`.
///
/// Returns the detected language asynchronously. The caller hot-swaps
/// the transcriber locale if the result differs from the initial locale.
/// First few seconds of transcription may use the wrong locale — this is
/// the acceptable tradeoff for zero startup delay.
@available(macOS 26.0, *)
public enum AudioLanguageProbe {
  /// Minimum speech audio to collect before running detection.
  public static let minSpeechSeconds: Double = 2.0

  /// Maximum time to wait for enough speech before giving up.
  public static let maxWaitSeconds: Double = 30.0

  /// RMS threshold for speech frames. WhisperKit's EnergyVAD uses 0.02;
  /// we use 0.015 to catch quieter speech while still rejecting silence.
  public static let speechRMSThreshold: Float = 0.015

  /// Frame length in samples for energy check (100ms at 16kHz).
  public static let frameSamples: Int = 1600

  /// Run language detection concurrently. Buffers speech audio from the
  /// multicast subscription, skipping silence, then detects language.
  ///
  /// Call this from a `Task {}` so it doesn't block the main pipeline.
  public static func detect(
    stream: AsyncStream<PCMBufferRef>,
    sampleRate: Double,
    detector: AudioLanguageDetector,
    candidates: Set<String>? = nil,
    logTag: String = "locale"
  ) async throws -> (language: String, confidence: Double)? {
    let minSamples = Int(sampleRate * minSpeechSeconds)
    var speechSamples = [Float]()
    speechSamples.reserveCapacity(minSamples)

    let deadline = ContinuousClock.now + .seconds(maxWaitSeconds)

    for await ref in stream {
      let buffer = ref.buffer
      let count = Int(buffer.frameLength)
      guard count > 0 else { continue }

      // Extract float samples from the buffer.
      var chunk = [Float]()
      chunk.reserveCapacity(count)
      if let int16 = buffer.int16ChannelData {
        let ptr = int16[0]
        let scale: Float = 1.0 / 32_768.0
        for i in 0..<count { chunk.append(Float(ptr[i]) * scale) }
      } else if let fp = buffer.floatChannelData {
        let ptr = fp[0]
        for i in 0..<count { chunk.append(ptr[i]) }
      }
      guard !chunk.isEmpty else { continue }

      // Only keep frames with speech energy.
      var offset = 0
      while offset + frameSamples <= chunk.count {
        let frame = chunk[offset..<(offset + frameSamples)]
        let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frameSamples))
        if rms >= speechRMSThreshold {
          speechSamples.append(contentsOf: frame)
        }
        offset += frameSamples
      }
      // Tail partial frame — keep if it has energy.
      if offset < chunk.count {
        let tail = chunk[offset...]
        let rms = sqrt(tail.reduce(Float(0)) { $0 + $1 * $1 } / Float(tail.count))
        if rms >= speechRMSThreshold {
          speechSamples.append(contentsOf: tail)
        }
      }

      if speechSamples.count >= minSamples { break }
      if ContinuousClock.now > deadline { break }
    }

    guard !speechSamples.isEmpty else {
      FileHandle.standardError.write(Data(
        "[\(logTag).audio-detect] no speech detected in \(maxWaitSeconds)s; skipping\n".utf8
      ))
      return nil
    }

    let secs = String(format: "%.1f", Double(speechSamples.count) / sampleRate)
    FileHandle.standardError.write(Data(
      "[\(logTag).audio-detect] collected \(secs)s of speech; detecting language\n".utf8
    ))

    // Resample to 16kHz if needed.
    let samples: [Float]
    if abs(sampleRate - 16_000) < 1.0 {
      samples = speechSamples
    } else {
      let ratio = 16_000.0 / sampleRate
      let outCount = Int(Double(speechSamples.count) * ratio)
      var resampled = [Float](repeating: 0, count: outCount)
      for i in 0..<outCount {
        let srcIdx = Double(i) / ratio
        let lo = Int(srcIdx)
        let hi = min(lo + 1, speechSamples.count - 1)
        let frac = Float(srcIdx - Double(lo))
        resampled[i] = speechSamples[lo] * (1 - frac) + speechSamples[hi] * frac
      }
      samples = resampled
    }

    return try await detector.detect(audioSamples: samples, candidates: candidates)
  }
}
