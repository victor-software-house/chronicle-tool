import Testing
@testable import Chronicle

@Suite("LiveCaptureConfiguration")
struct LiveCaptureConfigurationTests {
  @Test("normalizes direct mic and sysaudio settings")
  func normalizesDirectSettings() {
    let mic = LiveCaptureConfiguration.direct(
      source: .mic,
      locale: "auto",
      output: "trace.jsonl",
      append: "finals.md",
      live: "live.md",
      saveAudio: "audio.caf",
      audioFormat: "alac",
      diarize: true
    )
    let sysaudio = LiveCaptureConfiguration.direct(source: .sysaudio, locale: nil, output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)

    #expect(mic.source == .mic)
    #expect(mic.locale == "auto")
    #expect(mic.tracePath == "trace.jsonl")
    #expect(mic.diarizationEnabled)
    #expect(sysaudio.source == .sysaudio)
    #expect(sysaudio.locale == nil)
    #expect(!sysaudio.diarizationEnabled)
  }

  @Test("progressive layer changes are live apply")
  func progressiveLayerChangesAreLiveApply() {
    let config = LiveCaptureConfiguration.direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
    let decision = config.policy(for: .setDiarization(enabled: true), whileActive: true)

    #expect(decision == .applyLive(reason: "progressive layer change keeps rough transcript active"))
  }

  @Test("audio sidecar format changes are rejected while active with alternative")
  func audioSidecarFormatChangesAreRejectedWhileActiveWithAlternative() {
    let config = LiveCaptureConfiguration.direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: true)
    let decision = config.policy(for: .setAudioFormat("wav"), whileActive: true)

    guard case .reject(let reason, let alternative) = decision else {
      Issue.record("expected rejection, got \(decision)")
      return
    }
    #expect(reason.contains("audio sidecar format"))
    #expect(alternative.contains("start a new segment"))
  }

  @Test("rotation changes apply to future segments only")
  func rotationChangesApplyToFutureSegmentsOnly() {
    let config = LiveCaptureConfiguration.direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
    #expect(config.policy(for: .setRotateAudio(seconds: 30), whileActive: true) == .futureSegment(reason: "rotation changes apply when the next audio segment opens"))
  }

  @Test("inactive configuration changes can be applied before start")
  func inactiveConfigurationChangesCanBeAppliedBeforeStart() {
    let config = LiveCaptureConfiguration.direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
    #expect(config.policy(for: .setLocale("en-US"), whileActive: false) == .applyBeforeStart)
    #expect(config.policy(for: .setAudioFormat("wav"), whileActive: false) == .applyBeforeStart)
  }
}
