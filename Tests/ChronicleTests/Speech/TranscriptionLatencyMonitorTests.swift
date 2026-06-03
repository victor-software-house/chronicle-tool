import Testing
@testable import ChronicleCore

struct TranscriptionLatencyMonitorTests {
  @Test("latency is receipt offset minus audio range end")
  func computesLatencyFromAudioEnd() {
    let latency = TranscriptionLatencyMonitor.transcriptionLatencyMs(
      wallclockOffsetMs: 1_750.0,
      audioRange: TraceAudioRange(startSeconds: 0.25, endSeconds: 1.25)
    )

    #expect(latency == 500.0)
  }

  @Test("monitor emits warnings for high latency")
  func emitsWarningsForHighLatency() {
    var monitor = TranscriptionLatencyMonitor(
      logTag: "test",
      diagnosticIntervalSeconds: 999,
      warnLatencyMs: 500
    )

    let snapshot = monitor.record(
      isFinal: false,
      wallclockOffsetMs: 2_000,
      audioRange: TraceAudioRange(startSeconds: 0, endSeconds: 1),
      speakerId: nil
    )

    #expect(snapshot?.label == "warn")
    #expect(snapshot?.latestMs == 1_000)
  }

  @Test("missing audio range produces no latency sample")
  func missingAudioRangeProducesNoSample() {
    var monitor = TranscriptionLatencyMonitor(logTag: "test")

    let snapshot = monitor.record(
      isFinal: true,
      wallclockOffsetMs: 2_000,
      audioRange: nil,
      speakerId: "S0"
    )

    #expect(snapshot == nil)
    #expect(monitor.finalSnapshot() == nil)
  }

  @Test("monitor tracks final samples but emits only on diagnostic ticks")
  func tracksFinalSnapshotWithoutPerFinalEmission() {
    var monitor = TranscriptionLatencyMonitor(
      logTag: "test",
      diagnosticIntervalSeconds: 999,
      warnLatencyMs: 999_000
    )

    _ = monitor.record(
      isFinal: false,
      wallclockOffsetMs: 1_100,
      audioRange: TraceAudioRange(startSeconds: 0, endSeconds: 1),
      speakerId: nil
    )
    let snapshot = monitor.record(
      isFinal: true,
      wallclockOffsetMs: 2_300,
      audioRange: TraceAudioRange(startSeconds: 1, endSeconds: 2),
      speakerId: "S0"
    )
    let finalSnapshot = monitor.finalSnapshot()

    #expect(snapshot == nil)
    #expect(finalSnapshot?.label == "summary")
    #expect(finalSnapshot?.latestMs == 300)
    #expect(finalSnapshot?.sampleCount == 2)
    #expect(finalSnapshot?.finalCount == 1)
    #expect(finalSnapshot?.speakerKnownCount == 1)
    #expect(finalSnapshot?.speakerUnknownCount == 1)
    #expect(finalSnapshot?.averageMs == 200)
    #expect(finalSnapshot?.maxMs == 300)
  }
}
