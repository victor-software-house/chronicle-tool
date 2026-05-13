import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import Speech

#if canImport(Darwin)
import Darwin
#endif

/// `AudioSource` backed by ScreenCaptureKit's `SCStream` audio-only path.
///
/// Captures the system mix (every app's audio output combined) at the
/// platform's default rate (typically 48 kHz Float32 stereo) and converts
/// per-buffer into the analyzer's preferred format (16 kHz Int16 mono).
///
/// Requires the user to grant Screen Recording permission (TCC):
/// - Info.plist must carry `NSScreenCaptureUsageDescription`.
/// - First run triggers the macOS permission prompt.
/// - If denied, the user must re-enable in
///   `System Settings → Privacy & Security → Screen Recording`.
///
/// Notes:
/// - `excludesCurrentProcessAudio = true` prevents feedback when chronicle
///   itself plays audio. Disable explicitly if the caller needs self-audio.
/// - On Apple Silicon, system audio capture is hardware-accelerated and
///   costs effectively nothing in CPU.
public final class SysAudioSource: NSObject, AudioSource, SCStreamOutput, @unchecked Sendable {
  public let analyzerFormat: AVAudioFormat
  public let analyzerInputs: AsyncStream<AnalyzerInput>
  public let pcmBuffers: AsyncStream<PCMBufferRef>

  /// Format that `SCStream` actually delivers (set after `start()`).
  /// Used by the converter; exposed for diagnostics.
  public private(set) var sourceFormat: AVAudioFormat?

  private let excludeSelf: Bool
  private let analyzerBuilder: AsyncStream<AnalyzerInput>.Continuation
  private let pcmBuilder: AsyncStream<PCMBufferRef>.Continuation

  private var stream: SCStream?
  private var converter: BufferConverter?
  private var started = false
  private var stopped = false

  /// Diagnostic counters — informational, not synchronised. Useful for
  /// `--verbose` runs and for tests that assert the source is producing
  /// non-silent buffers.
  public private(set) var buffersReceived: Int = 0
  public private(set) var peakSample: Int16 = 0
  /// When true, the source logs per-buffer diagnostics every 64 buffers
  /// (~1.2 s at the default 16 kHz mono rate). Off by default to keep the
  /// hot path clean.
  public var verbose: Bool = false

  public init(analyzerFormat: AVAudioFormat, excludeCurrentProcessAudio: Bool = true) {
    self.analyzerFormat = analyzerFormat
    self.excludeSelf = excludeCurrentProcessAudio

    var aBuilder: AsyncStream<AnalyzerInput>.Continuation!
    self.analyzerInputs = AsyncStream { aBuilder = $0 }
    self.analyzerBuilder = aBuilder

    var pBuilder: AsyncStream<PCMBufferRef>.Continuation!
    self.pcmBuffers = AsyncStream { pBuilder = $0 }
    self.pcmBuilder = pBuilder

    super.init()
  }

  /// Begin capture. Throws `SysAudioSourceError.permissionDenied` when the
  /// user has not granted Screen Recording; throws
  /// `.noDisplayAvailable` when `SCShareableContent` returns no displays
  /// (headless machine, locked screen, etc.).
  ///
  /// Async because `SCShareableContent` and `SCStream.startCapture` are
  /// both async APIs; the legacy completion-handler variants warn under
  /// Swift 6 strict concurrency.
  public func start() async throws {
    guard !started else { return }
    started = true

    // Capture the entire shareable content; we only want the audio mix so
    // the display choice is cosmetic, but SCContentFilter requires one.
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
      throw SysAudioSourceError.permissionDenied(underlying: error)
    }
    guard let display = content.displays.first else {
      throw SysAudioSourceError.noDisplayAvailable
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = excludeSelf
    // Match the analyzer's mono preference at the source where possible;
    // the converter still runs but the input frame count stays smaller.
    config.sampleRate = Int(analyzerFormat.sampleRate)
    config.channelCount = 1
    // Minimum video config (we don't capture video; required by API).
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.width = 2
    config.height = 2

    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

    do {
      try await stream.startCapture()
    } catch {
      throw SysAudioSourceError.startFailed(underlying: error)
    }

    self.stream = stream
  }

  public func stop() {
    guard started, !stopped else { return }
    stopped = true
    if let stream = stream {
      Task { try? await stream.stopCapture() }
    }
    analyzerBuilder.finish()
    pcmBuilder.finish()
  }

  // MARK: SCStreamOutput

  public func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, sampleBuffer.isValid else { return }

    // Unwrap audio buffer list + format description.
    guard let formatDesc = sampleBuffer.formatDescription,
          let asbd = formatDesc.audioStreamBasicDescription else { return }

    var sourceFmt = self.sourceFormat
    if sourceFmt == nil {
      let fmt = AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 })
      sourceFmt = fmt
      self.sourceFormat = fmt
      if let fmt {
        self.converter = BufferConverter(from: fmt, to: analyzerFormat)
        if verbose {
          FileHandle.standardError.write(Data(
            "[sysaudio.src] first buffer; sourceFormat=\(fmt) commonFormat=\(fmt.commonFormat.rawValue) interleaved=\(fmt.isInterleaved)\n".utf8
          ))
        }
      }
    }
    guard let sourceFmt, let converter else { return }

    guard let input = makePCMBuffer(from: sampleBuffer, format: sourceFmt) else { return }
    guard let converted = converter.convert(input) else { return }

    buffersReceived += 1
    // Cheap peak-amplitude check on the Int16 output every 64 buffers.
    // Only printed when --verbose is enabled; the peak field is always
    // updated so tests / consumers can assert signal presence.
    if buffersReceived % 64 == 0, let int16Data = converted.int16ChannelData {
      let count = Int(converted.frameLength)
      var peak: Int16 = 0
      let ptr = int16Data[0]
      for i in 0..<count {
        let s = ptr[i]
        let mag: Int16 = s < 0 ? (s == Int16.min ? Int16.max : -s) : s
        if mag > peak { peak = mag }
      }
      if peak > peakSample { peakSample = peak }
      if verbose {
        FileHandle.standardError.write(Data(
          "[sysaudio.src] buffers=\(buffersReceived) lastPeak=\(peak) sessionPeak=\(peakSample) (Int16 ±32767)\n".utf8
        ))
      }
    }

    analyzerBuilder.yield(AnalyzerInput(buffer: converted))
    pcmBuilder.yield(PCMBufferRef(converted))
  }

  /// Materialise an `AVAudioPCMBuffer` from a `CMSampleBuffer` produced by
  /// `SCStream`. The sample buffer carries a `CMBlockBuffer` of audio bytes;
  /// we copy into a fresh `AVAudioPCMBuffer` so downstream consumers can
  /// retain it past the SCStream callback.
  private func makePCMBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let numSamples = CMSampleBufferGetNumSamples(sample)
    guard numSamples > 0,
          let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }

    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer,
      atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset,
      totalLengthOut: &totalLength,
      dataPointerOut: &dataPointer
    )
    guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
      return nil
    }
    pcm.frameLength = AVAudioFrameCount(numSamples)

    // Copy bytes into the PCM buffer's underlying channel data. For
    // Float32 non-interleaved (SCStream default) channelData is an array
    // of pointers; for interleaved formats it's a single pointer.
    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
    let totalBytes = min(totalLength, Int(numSamples) * bytesPerFrame)
    if let channelData = pcm.floatChannelData {
      // Float32 non-interleaved (typical SCStream output).
      memcpy(channelData[0], dataPointer, totalBytes)
    } else if let int16Data = pcm.int16ChannelData {
      memcpy(int16Data[0], dataPointer, totalBytes)
    } else {
      return nil
    }
    return pcm
  }
}

public enum SysAudioSourceError: Error, CustomStringConvertible {
  case permissionDenied(underlying: Error)
  case noDisplayAvailable
  case startFailed(underlying: Error)

  public var description: String {
    switch self {
    case .permissionDenied(let e):
      return "Screen Recording permission denied (\(e.localizedDescription)). Open System Settings → Privacy & Security → Screen Recording and enable chronicle."
    case .noDisplayAvailable:
      return "No display available for SCStream content filter (locked screen? headless machine?)."
    case .startFailed(let e):
      return "SCStream.startCapture failed: \(e.localizedDescription)"
    }
  }
}
