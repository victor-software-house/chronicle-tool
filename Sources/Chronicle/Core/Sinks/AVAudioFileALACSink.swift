import Foundation
@preconcurrency import AVFoundation

/// Apple Lossless (ALAC) sidecar writer using the highest-level Apple file API.
///
/// This is the preferred P11 implementation path from ADR-0002's 2026-05-16
/// amendment: let `AVAudioFile` own CAF container writing, ALAC encoder setup,
/// magic-cookie handling, packet tables, and finalization. Chronicle only feeds
/// the writer rounded Int16 PCM, which is the storage shape that passed the real
/// 6870 s reference WER/size probe.
///
/// `ALACCAFSink` (ExtAudioFile) remains the fallback only if this high-level
/// writer fails the concrete acceptance tests: wrong codec/container, bloated
/// output, failed readback, or WER drift.
public final class AVAudioFileALACSink: AudioSidecarSink, @unchecked Sendable {
  private let url: URL
  private let sourceFormat: AVAudioFormat
  private let int16Format: AVAudioFormat
  private let converter: AVAudioConverter?
  private var file: AVAudioFile?

  public init(url: URL, sourceFormat: AVAudioFormat) throws {
    self.url = url
    self.sourceFormat = sourceFormat

    guard let int16Format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sourceFormat.sampleRate,
      channels: sourceFormat.channelCount,
      interleaved: false
    ) else {
      throw AVAudioFileALACSinkError.formatCreationFailed
    }
    self.int16Format = int16Format

    if sourceFormat.commonFormat == .pcmFormatInt16
      && sourceFormat.sampleRate == int16Format.sampleRate
      && sourceFormat.channelCount == int16Format.channelCount
      && !sourceFormat.isInterleaved
    {
      self.converter = nil
    } else {
      guard let converter = AVAudioConverter(from: sourceFormat, to: int16Format) else {
        throw AVAudioFileALACSinkError.converterCreationFailed
      }
      self.converter = converter
    }

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatAppleLossless,
      AVSampleRateKey: sourceFormat.sampleRate,
      AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
      AVEncoderBitDepthHintKey: 16
    ]

    self.file = try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: .pcmFormatInt16,
      interleaved: false
    )
  }

  public func append(_ buffer: AVAudioPCMBuffer) async {
    guard buffer.frameLength > 0, let file else { return }

    do {
      _ = try write(buffer, to: file)
    } catch {
      FileHandle.standardError.write(Data(
        "[AVAudioFileALACSink] write failed: \(error)\n".utf8
      ))
    }
  }

  @discardableResult
  public func appendOrThrow(_ buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    guard buffer.frameLength > 0, let file else { return 0 }
    return try write(buffer, to: file)
  }

  public func finish() async {
    // AVAudioFile finalizes container metadata on close/deinit. Release the
    // reference deterministically so follow-up verification can reopen the CAF.
    if #available(macOS 15.0, *) {
      file?.close()
    }
    file = nil
  }

  private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws -> AVAudioFrameCount {
    let out: AVAudioPCMBuffer
    if let converter {
      out = try convert(buffer, with: converter)
    } else {
      out = buffer
    }

    guard out.frameLength > 0 else { return 0 }
    try file.write(from: out)
    return out.frameLength
  }

  private func convert(
    _ input: AVAudioPCMBuffer,
    with converter: AVAudioConverter
  ) throws -> AVAudioPCMBuffer {
    let capacity = AVAudioFrameCount(
      ceil(Double(input.frameLength) * int16Format.sampleRate / sourceFormat.sampleRate)
    )
    guard capacity > 0,
          let output = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: capacity)
    else { throw AVAudioFileALACSinkError.bufferAllocationFailed }

    var didProvideInput = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      if didProvideInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return input
    }

    if status == .error {
      throw AVAudioFileALACSinkError.conversionFailed(error?.localizedDescription ?? "unknown")
    }
    guard output.frameLength > 0 else {
      throw AVAudioFileALACSinkError.conversionProducedNoFrames
    }
    return output
  }
}

public enum AVAudioFileALACSinkError: Error, CustomStringConvertible {
  case formatCreationFailed
  case converterCreationFailed
  case bufferAllocationFailed
  case conversionFailed(String)
  case conversionProducedNoFrames

  public var description: String {
    switch self {
    case .formatCreationFailed:
      return "Failed to create Int16 PCM format for AVAudioFile ALAC sink"
    case .converterCreationFailed:
      return "Failed to create AVAudioConverter for AVAudioFile ALAC sink"
    case .bufferAllocationFailed:
      return "Failed to allocate Int16 PCM buffer for AVAudioFile ALAC sink"
    case .conversionFailed(let message):
      return "Failed to convert PCM buffer for AVAudioFile ALAC sink: \(message)"
    case .conversionProducedNoFrames:
      return "PCM conversion produced no frames for AVAudioFile ALAC sink"
    }
  }
}
