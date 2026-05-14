import Foundation
import AVFoundation

/// Lossless rolling raw-PCM scratch tier (per ADR-0002): the last ~5 minutes
/// of audio kept on disk as raw PCM segments alongside the Opus-in-CAF
/// production stream, so we can pull a high-fidelity copy of a recent
/// moment without committing the full 24/7 stream to lossless storage.
///
/// Layout under `<base>/`:
///
///     <base>/000000.pcm   ← oldest segment still within TTL
///     <base>/000001.pcm
///     ...
///     <base>/0000NN.pcm   ← currently-being-written segment
///     <base>/format.json  ← sample rate / channels / bit depth / float-or-int metadata
///
/// Each `.pcm` is a flat header-less interleaved PCM block in the source
/// format. Segments rotate every `rotateInterval` seconds; segments older
/// than `ttl` seconds are pruned on rotation. The on-disk size budget is
/// strictly bounded by `ttl * source-bandwidth`.
///
/// **Crash safety:** because the scratch is header-less raw PCM, a SIGKILL
/// at any point leaves a perfectly-readable file truncated to the last
/// successful flush. No `chronicle repair` needed.
public final class RollingPCMScratchSink: AudioSidecarSink, @unchecked Sendable {

  // MARK: - Configuration

  public static let defaultTTLSeconds: Double = 300.0
  public static let defaultRotateSeconds: Double = 30.0

  // MARK: - State

  private let base: URL
  private let sourceFormat: AVAudioFormat
  private let ttl: Double
  private let rotateInterval: Double

  private var currentURL: URL?
  private var currentHandle: FileHandle?
  private var currentSegmentIndex: Int = 0
  private var currentSegmentStart: Date = Date()
  private var closed: Bool = false

  // MARK: - Init

  /// - Parameters:
  ///   - base: directory holding the scratch segments. Created if missing.
  ///   - sourceFormat: format of incoming buffers (analyzer format).
  ///   - ttl: max age of a segment on disk before pruning (seconds).
  ///   - rotateInterval: how often to start a new segment (seconds).
  public init(
    base: URL,
    sourceFormat: AVAudioFormat,
    ttl: Double = RollingPCMScratchSink.defaultTTLSeconds,
    rotateInterval: Double = RollingPCMScratchSink.defaultRotateSeconds
  ) throws {
    self.base = base
    self.sourceFormat = sourceFormat
    self.ttl = ttl
    self.rotateInterval = rotateInterval

    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

    // Discover existing segments so a daemon restart picks up where it left
    // off. Use the highest existing index + 1 as next.
    if let existing = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
      let pcmFiles = existing.filter { $0.pathExtension == "pcm" }
      let maxIndex = pcmFiles.compactMap { Int($0.deletingPathExtension().lastPathComponent) }.max() ?? -1
      self.currentSegmentIndex = maxIndex + 1
    }

    // Persist the format manifest so an offline consumer (transcribe /
    // diarize) knows how to interpret the headerless PCM files.
    try writeFormatManifest()

    try openNextSegment()
  }

  // MARK: - AudioSidecarSink

  public func append(_ buffer: AVAudioPCMBuffer) async {
    guard !closed else { return }

    // Rotate if interval elapsed.
    if Date().timeIntervalSince(currentSegmentStart) >= rotateInterval {
      try? rotateSegment()
    }

    // Serialise the buffer as raw interleaved bytes in source format.
    guard let bytes = bufferToBytes(buffer) else { return }
    do {
      try currentHandle?.write(contentsOf: bytes)
    } catch {
      FileHandle.standardError.write(Data(
        "[RollingPCMScratchSink] write error: \(error.localizedDescription)\n".utf8
      ))
    }
  }

  public func finish() async {
    guard !closed else { return }
    try? currentHandle?.close()
    currentHandle = nil
    closed = true
  }

  // MARK: - Private

  private func writeFormatManifest() throws {
    let manifest: [String: Any] = [
      "sampleRate": sourceFormat.sampleRate,
      "channelCount": sourceFormat.channelCount,
      "commonFormat": commonFormatName(sourceFormat.commonFormat),
      "interleaved": sourceFormat.isInterleaved,
      "bitsPerChannel": bitsPerChannel(sourceFormat),
      "ttl": ttl,
      "rotateInterval": rotateInterval
    ]
    let data = try JSONSerialization.data(
      withJSONObject: manifest,
      options: [.prettyPrinted, .sortedKeys]
    )
    let manifestURL = base.appendingPathComponent("format.json")
    try data.write(to: manifestURL, options: .atomic)
  }

  private func openNextSegment() throws {
    let name = String(format: "%06d.pcm", currentSegmentIndex)
    let url = base.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    currentURL = url
    currentHandle = handle
    currentSegmentStart = Date()
  }

  private func rotateSegment() throws {
    // Close current segment.
    try? currentHandle?.close()
    currentHandle = nil
    currentSegmentIndex += 1
    try openNextSegment()

    // Prune segments older than TTL.
    pruneStaleSegments()
  }

  private func pruneStaleSegments() {
    let cutoff = Date().addingTimeInterval(-ttl)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: base,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    for u in entries where u.pathExtension == "pcm" {
      guard u != currentURL else { continue }
      let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let m = mtime, m < cutoff {
        try? FileManager.default.removeItem(at: u)
      }
    }
  }

  private func bufferToBytes(_ buffer: AVAudioPCMBuffer) -> Data? {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else { return nil }

    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
      guard let ch = buffer.floatChannelData else { return nil }
      // Interleave: [c0f0, c1f0, c0f1, c1f1, ...] if multi-channel; mono
      // is the typical chronicle path.
      var data = Data(count: frames * channels * MemoryLayout<Float>.size)
      data.withUnsafeMutableBytes { raw in
        let dst = raw.bindMemory(to: Float.self)
        for f in 0..<frames {
          for c in 0..<channels {
            dst[f * channels + c] = ch[c][f]
          }
        }
      }
      return data
    case .pcmFormatInt16:
      guard let ch = buffer.int16ChannelData else { return nil }
      var data = Data(count: frames * channels * MemoryLayout<Int16>.size)
      data.withUnsafeMutableBytes { raw in
        let dst = raw.bindMemory(to: Int16.self)
        for f in 0..<frames {
          for c in 0..<channels {
            dst[f * channels + c] = ch[c][f]
          }
        }
      }
      return data
    case .pcmFormatInt32:
      guard let ch = buffer.int32ChannelData else { return nil }
      var data = Data(count: frames * channels * MemoryLayout<Int32>.size)
      data.withUnsafeMutableBytes { raw in
        let dst = raw.bindMemory(to: Int32.self)
        for f in 0..<frames {
          for c in 0..<channels {
            dst[f * channels + c] = ch[c][f]
          }
        }
      }
      return data
    default:
      return nil
    }
  }

  private func commonFormatName(_ f: AVAudioCommonFormat) -> String {
    switch f {
    case .pcmFormatFloat32: return "float32"
    case .pcmFormatFloat64: return "float64"
    case .pcmFormatInt16:   return "int16"
    case .pcmFormatInt32:   return "int32"
    case .otherFormat:      return "other"
    @unknown default:       return "unknown"
    }
  }

  private func bitsPerChannel(_ f: AVAudioFormat) -> Int {
    switch f.commonFormat {
    case .pcmFormatFloat32, .pcmFormatInt32: return 32
    case .pcmFormatFloat64:                  return 64
    case .pcmFormatInt16:                    return 16
    default:                                 return 0
    }
  }
}
