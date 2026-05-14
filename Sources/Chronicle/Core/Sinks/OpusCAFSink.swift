import Foundation
import AVFoundation
import AudioToolbox

/// Production-default raw-audio sidecar (per ADR-0002 amended 2026-05-13):
/// Opus 24 kbps mono encoded via Apple's native `AudioToolbox` Opus encoder,
/// wrapped in CAF (Core Audio Format) — Apple's canonical container for
/// Opus on macOS.
///
/// Pipeline:
///
///     AVAudioPCMBuffer (analyzer format, e.g. 16 kHz Float32 mono)
///       → AVAudioConverter (encode + resample to 48 kHz)
///       → AVAudioCompressedBuffer (N Opus packets, ~20 ms each)
///       → AudioFileWritePackets → CAF (kAudioFileCAFType)
///
/// Crash safety: CAF is chunk-based; `AudioFile` flushes packet data
/// continuously and has no fixed-size header to patch at finish (unlike
/// RIFF/WAV). Worst-case loss on SIGKILL is the in-flight ~20 ms packet,
/// which satisfies PRD-001 NFR "audio loss ≤ 60 s after unclean termination".
///
/// `.opus` (Ogg) consumers, if ever needed, can rewrap one-shot via
/// `ffmpeg -i in.caf -c:a copy out.opus` — no re-encode, bit-exact.
public final class OpusCAFSink: AudioSidecarSink, @unchecked Sendable {

  // MARK: - Configuration

  /// Default target bitrate (24 kbps mono is the chronicle production
  /// setting per ADR-0002; speech-band intelligibility well above STT
  /// noise floor).
  public static let defaultBitRate: Int = 24_000

  /// Default frames-per-packet at the Opus internal 48 kHz rate
  /// (20 ms = 960 frames). Other valid values: 120/240/480/960/1920/2880.
  public static let defaultFramesPerPacket: UInt32 = 960

  // MARK: - State

  private let url: URL
  private let sourceFormat: AVAudioFormat
  private let opusFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private let audioFile: AudioFileID
  private let outBuf: AVAudioCompressedBuffer
  private let drainBuf: AVAudioCompressedBuffer
  private var nextPacketIndex: Int64 = 0
  private var pendingInput: AVAudioPCMBuffer?
  private var closed: Bool = false

  // MARK: - Init

  /// - Parameters:
  ///   - url: output `.caf` file URL.
  ///   - sourceFormat: format of incoming `AVAudioPCMBuffer`s (analyzer
  ///     format, e.g. 16 kHz Float32 mono).
  ///   - bitRate: target Opus bitrate in bits/sec (default 24 000).
  ///     Supported values are queried at init via
  ///     `AVAudioConverter.applicableEncodeBitRates`; the closest valid
  ///     value is selected if the requested rate is unsupported.
  ///   - framesPerPacket: Opus frame size at 48 kHz internal rate
  ///     (default 960 = 20 ms).
  public init(
    url: URL,
    sourceFormat: AVAudioFormat,
    bitRate: Int = OpusCAFSink.defaultBitRate,
    framesPerPacket: UInt32 = OpusCAFSink.defaultFramesPerPacket
  ) throws {
    self.url = url
    self.sourceFormat = sourceFormat

    // Build Opus output ASBD. Apple's Opus encoder runs at 48 kHz internally;
    // input sample-rate conversion is handled by AVAudioConverter.
    var opusDesc = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatOpus,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: framesPerPacket,
      mBytesPerFrame: 0,
      mChannelsPerFrame: sourceFormat.channelCount,
      mBitsPerChannel: 0,
      mReserved: 0
    )
    guard let opusFmt = AVAudioFormat(streamDescription: &opusDesc) else {
      throw OpusCAFSinkError.opusFormatInitFailed
    }
    self.opusFormat = opusFmt

    guard let conv = AVAudioConverter(from: sourceFormat, to: opusFmt) else {
      throw OpusCAFSinkError.converterInitFailed(
        source: sourceFormat.description,
        destination: opusFmt.description
      )
    }
    // Snap requested bitrate to the closest supported value.
    if let applicable = conv.applicableEncodeBitRates as? [Int], !applicable.isEmpty {
      let snapped = applicable.min(by: { abs($0 - bitRate) < abs($1 - bitRate) }) ?? bitRate
      conv.bitRate = snapped
    } else {
      conv.bitRate = bitRate
    }
    self.converter = conv

    // Open the CAF file for streaming Opus packet writes.
    // Use `eraseFile` so re-runs clobber the previous capture.
    var file: AudioFileID?
    let status = AudioFileCreateWithURL(
      url as CFURL,
      kAudioFileCAFType,
      &opusDesc,
      AudioFileFlags.eraseFile,
      &file
    )
    guard status == noErr, let af = file else {
      throw OpusCAFSinkError.audioFileCreateFailed(status: status)
    }
    self.audioFile = af

    // Reusable compressed-buffer scratch space. Generous packet capacity
    // and per-packet upper bound; the converter writes whatever fits.
    let packetCapacity: AVAudioPacketCount = 64
    let maxPacketSize: Int = 1500
    self.outBuf = AVAudioCompressedBuffer(
      format: opusFmt,
      packetCapacity: packetCapacity,
      maximumPacketSize: maxPacketSize
    )
    self.drainBuf = AVAudioCompressedBuffer(
      format: opusFmt,
      packetCapacity: packetCapacity,
      maximumPacketSize: maxPacketSize
    )
  }

  // MARK: - AudioSidecarSink

  public func append(_ buffer: AVAudioPCMBuffer) async {
    guard !closed else { return }
    pendingInput = buffer

    // Loop the converter while it keeps producing output. The input
    // callback returns `.haveData` when `pendingInput` is set and
    // `.noDataNow` once we have handed it over; the converter then
    // returns zero packets and we break out, waiting for the next
    // `append(_:)`.
    while !closed {
      outBuf.packetCount = 0
      outBuf.byteLength = 0
      var convError: NSError?
      _ = converter.convert(
        to: outBuf,
        error: &convError,
        withInputFrom: { [weak self] _, outStatus in
          guard let self = self else {
            outStatus.pointee = .endOfStream
            return nil
          }
          if let buf = self.pendingInput {
            self.pendingInput = nil
            outStatus.pointee = .haveData
            return buf
          }
          outStatus.pointee = .noDataNow
          return nil
        }
      )

      if let err = convError {
        FileHandle.standardError.write(Data(
          "[OpusCAFSink] convert error: \(err.localizedDescription)\n".utf8
        ))
        return
      }

      if outBuf.packetCount > 0 {
        writePackets(outBuf)
      } else {
        // Converter wants more input than we have right now. Wait for
        // the next `append(_:)`.
        break
      }
    }
  }

  public func finish() async {
    guard !closed else { return }

    // Drain converter internal state with an `.endOfStream` signal.
    drainBuf.packetCount = 0
    drainBuf.byteLength = 0
    var drainError: NSError?
    _ = converter.convert(
      to: drainBuf,
      error: &drainError,
      withInputFrom: { _, outStatus in
        outStatus.pointee = .endOfStream
        return nil
      }
    )
    if drainBuf.packetCount > 0 {
      writePackets(drainBuf)
    }

    closed = true
    AudioFileClose(audioFile)
  }

  // MARK: - Private

  private func writePackets(_ buf: AVAudioCompressedBuffer) {
    guard buf.packetCount > 0, let descs = buf.packetDescriptions else { return }
    var numPackets = UInt32(buf.packetCount)
    let status = AudioFileWritePackets(
      audioFile,
      false,  // useCache
      buf.byteLength,
      descs,
      nextPacketIndex,
      &numPackets,
      buf.data
    )
    if status != noErr {
      FileHandle.standardError.write(Data(
        "[OpusCAFSink] AudioFileWritePackets status=\(status)\n".utf8
      ))
      return
    }
    nextPacketIndex += Int64(numPackets)
  }
}

// MARK: - Errors

public enum OpusCAFSinkError: Error, CustomStringConvertible {
  case opusFormatInitFailed
  case converterInitFailed(source: String, destination: String)
  case audioFileCreateFailed(status: OSStatus)

  public var description: String {
    switch self {
    case .opusFormatInitFailed:
      return "Failed to construct AVAudioFormat for kAudioFormatOpus"
    case .converterInitFailed(let src, let dst):
      return "AVAudioConverter init failed for \(src) -> \(dst)"
    case .audioFileCreateFailed(let status):
      return "AudioFileCreateWithURL failed with OSStatus \(status)"
    }
  }
}
