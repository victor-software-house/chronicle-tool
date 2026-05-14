import Foundation
import AVFoundation

/// Lossless WAV (RIFF/Linear PCM) raw-audio sidecar. Opt-in via
/// `--audio-format wav` after the P11 default flip to Opus-in-CAF.
///
/// Writes whatever `AVAudioPCMBuffer` format is delivered (analyzer format
/// — usually 16 kHz Float32 mono or 16 kHz Int16 mono). RIFF/WAVE patches
/// the `data` chunk size on close, so this sink is **not** crash-safe;
/// SIGKILL between buffers leaves an unreadable file unless `chronicle
/// repair` (FR-8, P2) is run. CAF + Opus is the production-default
/// alternative.
public final class WAVSidecarSink: AudioSidecarSink, @unchecked Sendable {
  private let url: URL
  private var file: AVAudioFile?

  public init(url: URL, sourceFormat: AVAudioFormat) throws {
    self.url = url
    self.file = try AVAudioFile(
      forWriting: url,
      settings: sourceFormat.settings,
      commonFormat: sourceFormat.commonFormat,
      interleaved: sourceFormat.isInterleaved
    )
  }

  public func append(_ buffer: AVAudioPCMBuffer) async {
    try? file?.write(from: buffer)
  }

  public func finish() async {
    // AVAudioFile patches the WAV `data` chunk size and flushes on deinit.
    // Release the reference deterministically so the file is readable
    // before the consuming task awaits.
    file = nil
  }
}
