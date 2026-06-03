import Testing
@testable import ChronicleCore

@Suite("LiveCaptureSession")
struct LiveCaptureSessionTests {
  @Test("session can be constructed without opening live audio")
  func sessionCanBeConstructedWithoutOpeningLiveAudio() async throws {
    let config = LiveCaptureConfiguration.direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
    let session = LiveCaptureSession(configuration: config)

    let status = await session.status()
    #expect(status.source == .mic)
    #expect(status.lifecycle == .stopped)
    #expect(status.roughTranscriptActive == false)
    #expect(status.speakerLabelState == .unavailable)
  }

  @Test("start keeps rough transcript active before progressive layers")
  func startKeepsRoughTranscriptActiveBeforeProgressiveLayers() async throws {
    let config = LiveCaptureConfiguration.direct(source: .sysaudio, locale: "auto", output: "trace.jsonl", append: "finals.md", live: "live.md", saveAudio: "audio.caf", audioFormat: "alac", diarize: false)
    let session = LiveCaptureSession(configuration: config)

    let started = try await session.start()
    #expect(started.lifecycle == .capturing)
    #expect(started.roughTranscriptActive)
    #expect(started.speakerLabelState == .unavailable)
    #expect(started.sidecars.tracePath == "trace.jsonl")
  }

  @Test("progressive diarization reconfigure does not stop base capture")
  func progressiveDiarizationReconfigureDoesNotStopBaseCapture() async throws {
    let config = LiveCaptureConfiguration.direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
    let session = LiveCaptureSession(configuration: config)
    _ = try await session.start()

    let outcome = await session.reconfigure(.setDiarization(enabled: true))
    let status = await session.status()

    #expect(outcome == .appliedLive)
    #expect(status.lifecycle == .capturing)
    #expect(status.roughTranscriptActive)
    #expect(status.speakerLabelState == .warming)
  }

  @Test("unsafe active reconfigure is rejected without stopping capture")
  func unsafeActiveReconfigureIsRejectedWithoutStoppingCapture() async throws {
    let config = LiveCaptureConfiguration.direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
    let session = LiveCaptureSession(configuration: config)
    _ = try await session.start()

    let outcome = await session.reconfigure(.setAudioFormat("wav"))
    let status = await session.status()

    guard case .rejected(let reason, let alternative) = outcome else {
      Issue.record("expected rejected outcome")
      return
    }
    #expect(reason.contains("audio sidecar format"))
    #expect(alternative.contains("new segment"))
    #expect(status.lifecycle == .capturing)
    #expect(status.roughTranscriptActive)
  }

  @Test("stop returns stopped status")
  func stopReturnsStoppedStatus() async throws {
    let config = LiveCaptureConfiguration.direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
    let session = LiveCaptureSession(configuration: config)
    _ = try await session.start()

    let stopped = await session.stop(reason: .clientRequest)
    #expect(stopped.lifecycle == .stopped)
    #expect(stopped.roughTranscriptActive == false)
  }
}
