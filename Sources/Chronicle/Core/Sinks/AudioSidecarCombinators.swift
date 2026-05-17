import Foundation
import AVFoundation

/// Fan-out sidecar sink: writes each audio buffer to multiple child sinks.
///
/// Used by the FR-1 default path so durable ALAC and rolling raw-PCM scratch
/// advance together without duplicating the mic/sysaudio pipeline loops.
public final class CompositeAudioSidecarSink: AudioSidecarSink, @unchecked Sendable {
  private let sinks: [AudioSidecarSink]

  public init(_ sinks: [AudioSidecarSink]) {
    self.sinks = sinks
  }

  public func append(_ buffer: AVAudioPCMBuffer) async {
    for sink in sinks {
      await sink.append(buffer)
    }
  }

  public func finish() async {
    for sink in sinks {
      await sink.finish()
    }
  }
}

/// Audio-duration based segment rotation wrapper for file-backed sidecar sinks.
///
/// Rotation is based on incoming PCM duration, not wall clock, matching the
/// PRD-001 Q6 resolution. Buffers are never split; rotation happens before the
/// first buffer that would start after the configured duration boundary, so the
/// segment can exceed the target by at most one input buffer.
public final class RotatingAudioSidecarSink: AudioSidecarSink, @unchecked Sendable {
  public typealias SinkFactory = @Sendable (URL) throws -> AudioSidecarSink

  private let baseURL: URL
  private let rotateInterval: Double
  private let sourceFormat: AVAudioFormat
  private let factory: SinkFactory

  private var currentSink: AudioSidecarSink?
  private var currentIndex: Int = 1
  private var currentSegmentSeconds: Double = 0
  private var closed = false

  public init(
    baseURL: URL,
    rotateInterval: Double,
    sourceFormat: AVAudioFormat,
    factory: @escaping SinkFactory
  ) throws {
    precondition(rotateInterval > 0, "RotatingAudioSidecarSink requires a positive rotate interval")
    self.baseURL = baseURL
    self.rotateInterval = rotateInterval
    self.sourceFormat = sourceFormat
    self.factory = factory
    self.currentSink = try factory(Self.segmentURL(for: baseURL, index: currentIndex))
  }

  public func append(_ buffer: AVAudioPCMBuffer) async {
    guard !closed, buffer.frameLength > 0 else { return }

    if currentSegmentSeconds >= rotateInterval {
      await rotate()
    }

    await currentSink?.append(buffer)
    currentSegmentSeconds += Double(buffer.frameLength) / sourceFormat.sampleRate
  }

  public func finish() async {
    guard !closed else { return }
    closed = true
    await currentSink?.finish()
    currentSink = nil
  }

  public static func segmentURL(for baseURL: URL, index: Int) -> URL {
    let directory = baseURL.deletingLastPathComponent()
    let ext = baseURL.pathExtension
    let stem = baseURL.deletingPathExtension().lastPathComponent
    let numbered = String(format: "%@-%06d", stem, index)
    let filename = ext.isEmpty ? numbered : "\(numbered).\(ext)"
    return directory.appendingPathComponent(filename)
  }

  private func rotate() async {
    await currentSink?.finish()
    currentIndex += 1
    currentSegmentSeconds = 0
    do {
      currentSink = try factory(Self.segmentURL(for: baseURL, index: currentIndex))
    } catch {
      currentSink = nil
      closed = true
      FileHandle.standardError.write(Data(
        "[RotatingAudioSidecarSink] failed to open next segment: \(error)\n".utf8
      ))
    }
  }
}
