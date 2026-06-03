import CoreAudio
import Testing
@testable import ChronicleCore

@Suite("CoreAudioTapSource")
struct CoreAudioTapSourceTests {
  @Test("validates sane CoreAudio tap ASBD")
  func validatesSaneTapASBD() throws {
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    try CoreAudioTapSource.validateTapASBD(asbd)
  }

  @Test("materialises tap format from copied ASBD fields")
  func materialisesTapFormatFromCopiedFields() throws {
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    let format = try CoreAudioTapSource.audioFormat(fromTapASBD: asbd)

    #expect(format.sampleRate == 48_000)
    #expect(format.channelCount == 2)
    #expect(format.commonFormat == .pcmFormatFloat32)
    #expect(format.isInterleaved)
  }

  @Test("invalid tap ASBD maps to actionable System Audio permission error")
  func invalidTapASBDMapsToPermissionError() throws {
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 0,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: 0,
      mBytesPerPacket: 2_235_048_792,
      mFramesPerPacket: 1,
      mBytesPerFrame: 52_134_145,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 2_677_221_899,
      mReserved: 0
    )

    do {
      try CoreAudioTapSource.validateTapASBD(asbd)
      Issue.record("expected invalidTapFormat")
    } catch let error as CoreAudioTapSourceError {
      #expect(String(describing: error).contains("System Audio Recording"))
      #expect(String(describing: error).contains("invalid audio format"))
    }
  }

  @Test("formats no-buffer startup warning as non-fatal idle telemetry")
  func formatsNoBufferWarningAsNonFatalIdleTelemetry() {
    let warning = CoreAudioTapSource.noValidBuffersWarning(context: "startup", waitedSeconds: 5.0)

    #expect(warning.contains("warning"))
    #expect(warning.contains("still running"))
    #expect(warning.contains("waiting for system audio"))
    let recurringWarning = CoreAudioTapSource.noValidBuffersWarning(
      context: "startup",
      waitedSeconds: CoreAudioTapSource.recurringNoBufferWarningSeconds
    )

    #expect(!warning.contains("System Audio Recording permission is required"))
    #expect(CoreAudioTapSource.recurringNoBufferWarningSeconds > CoreAudioTapSource.noBufferWarningSeconds)
    #expect(recurringWarning.contains("\(CoreAudioTapSource.recurringNoBufferWarningSeconds)s"))
  }

  @Test("default output debounce coalesces transient switch notifications")
  func defaultOutputDebounceIntervalIsShortButNonZero() {
    #expect(CoreAudioTapSource.defaultOutputDebounceSeconds >= 0.5)
    #expect(CoreAudioTapSource.defaultOutputDebounceSeconds <= 0.75)
  }
}
