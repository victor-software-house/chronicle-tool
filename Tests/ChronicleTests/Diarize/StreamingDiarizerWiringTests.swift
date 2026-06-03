import AVFoundation
import Foundation
import Testing
@testable import ChronicleCore

/// Stub backend that records every call. Used to drive
/// `SortformerStreamingDiarizer` without loading any CoreML model.
final class StubStreamingBackend: StreamingDiarizerBackend, @unchecked Sendable {
  let lock = NSLock()
  var loaded = false
  var loadCount = 0
  var addAudioCalls: [Int] = []        // sample count per call
  var processCallCount = 0
  var finalizeCallCount = 0
  /// Queue of updates to return from `process()` (FIFO).
  var pendingProcessUpdates: [StreamingDiarizerUpdate] = []
  /// Update to return on `finalize()`.
  var finalizeUpdate: StreamingDiarizerUpdate?
  var loadDelayNanoseconds: UInt64 = 0

  func load() async throws {
    if loadDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: loadDelayNanoseconds)
    }
    lock.withLock {
      loadCount += 1
      loaded = true
    }
  }

  func addAudio(_ samples: [Float]) throws {
    lock.withLock { addAudioCalls.append(samples.count) }
  }

  func process() throws -> StreamingDiarizerUpdate? {
    lock.withLock {
      processCallCount += 1
      guard !pendingProcessUpdates.isEmpty else { return nil }
      return pendingProcessUpdates.removeFirst()
    }
  }

  func finalize() throws -> StreamingDiarizerUpdate? {
    lock.withLock {
      finalizeCallCount += 1
      return finalizeUpdate
    }
  }
}

@Suite("SortformerStreamingDiarizer wiring")
struct StreamingDiarizerWiringTests {
  // MARK: - Helpers

  private static func int16BufferRef(frameCount: Int, value: Int16 = 8192) -> PCMBufferRef {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let dst = buffer.int16ChannelData!.pointee
    for i in 0..<frameCount { dst[i] = value }
    return PCMBufferRef(buffer)
  }

  // MARK: - Tests

  @Test("load() is called exactly once on the first ingest")
  func loadCalledOnceOnFirstIngest() async throws {
    let backend = StubStreamingBackend()
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 16_000,
      backend: backend
    )
    let ref = Self.int16BufferRef(frameCount: 100)
    try await diarizer.ingest(ref)
    try await diarizer.ingest(ref)
    try await diarizer.ingest(ref)
    #expect(backend.loadCount == 1)
  }

  @Test("prepare() loads the backend before first ingest")
  func prepareLoadsBackendBeforeFirstIngest() async throws {
    let backend = StubStreamingBackend()
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 16_000,
      backend: backend
    )

    try await diarizer.prepare()
    try await diarizer.ingest(Self.int16BufferRef(frameCount: 100))

    #expect(backend.loadCount == 1)
    #expect(backend.addAudioCalls == [100])
  }

  @Test("concurrent prepare and first ingest share one backend load")
  func concurrentPrepareAndFirstIngestShareOneLoad() async throws {
    let backend = StubStreamingBackend()
    backend.loadDelayNanoseconds = 20_000_000
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 16_000,
      backend: backend
    )

    async let prepared: Void = diarizer.prepare()
    async let ingested: Void = diarizer.ingest(Self.int16BufferRef(frameCount: 100))
    _ = try await (prepared, ingested)

    #expect(backend.loadCount == 1)
    #expect(backend.addAudioCalls == [100])
  }

  @Test("addAudio is called once per ingested buffer with correct sample count")
  func addAudioCalledPerBufferWithCorrectCount() async throws {
    let backend = StubStreamingBackend()
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 16_000,
      backend: backend
    )
    let sizes = [800, 1600, 400, 2000, 100]
    for n in sizes {
      try await diarizer.ingest(Self.int16BufferRef(frameCount: n))
    }
    #expect(backend.addAudioCalls == sizes)
    let ingestCount = await diarizer.debugIngestCallCount
    let totalSamples = await diarizer.debugTotalSamplesIngested
    #expect(ingestCount == sizes.count)
    #expect(totalSamples == sizes.reduce(0, +))
  }

  @Test("process() fires every processEverySamples worth of audio")
  func processFiresOncePerWindow() async throws {
    let backend = StubStreamingBackend()
    // Trigger process every 1600 samples (= 100 ms @ 16 kHz) so the test
    // is small and deterministic.
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 1_600,
      backend: backend
    )
    // 10 buffers of 800 samples = 8000 samples total → 5 process windows.
    for _ in 0..<10 {
      try await diarizer.ingest(Self.int16BufferRef(frameCount: 800))
    }
    let processCount = await diarizer.debugProcessCallCount
    #expect(processCount == 5)
  }

  @Test("absorb merges process() updates into the timeline lookup")
  func absorbMergesUpdatesIntoLookup() async throws {
    let backend = StubStreamingBackend()
    backend.pendingProcessUpdates = [
      StreamingDiarizerUpdate(
        finalizedSegments: [
          DiarizationSegment(speakerId: "S0", startSeconds: 0, endSeconds: 1),
          DiarizationSegment(speakerId: "S1", startSeconds: 1, endSeconds: 2)
        ],
        tentativeSegments: []
      ),
      StreamingDiarizerUpdate(
        finalizedSegments: [
          DiarizationSegment(speakerId: "S0", startSeconds: 2, endSeconds: 3)
        ],
        tentativeSegments: []
      )
    ]
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 1_600,
      backend: backend
    )
    for _ in 0..<4 {
      try await diarizer.ingest(Self.int16BufferRef(frameCount: 800))
    }
    let lookup = await diarizer.currentLookup
    #expect(lookup.segments.count >= 3)
    let s0 = await diarizer.speakerId(forRange: TraceAudioRange(startSeconds: 0.0, endSeconds: 1.0))
    let s1 = await diarizer.speakerId(forRange: TraceAudioRange(startSeconds: 1.0, endSeconds: 2.0))
    let s2 = await diarizer.speakerId(forRange: TraceAudioRange(startSeconds: 2.0, endSeconds: 3.0))
    #expect(s0 == "S0")
    #expect(s1 == "S1")
    #expect(s2 == "S0")
  }

  @Test("finish() calls finalize() and absorbs its update")
  func finishCallsFinalizeAndAbsorbs() async throws {
    let backend = StubStreamingBackend()
    backend.finalizeUpdate = StreamingDiarizerUpdate(
      finalizedSegments: [
        DiarizationSegment(speakerId: "S0", startSeconds: 10, endSeconds: 11)
      ],
      tentativeSegments: []
    )
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 16_000,
      backend: backend
    )
    try await diarizer.ingest(Self.int16BufferRef(frameCount: 16_000))
    await diarizer.finish()
    #expect(backend.finalizeCallCount == 1)
    let lookup = await diarizer.currentLookup
    #expect(lookup.segments.contains { $0.startSeconds == 10 })
  }

  @Test("finish() skips finalize when no audio was ingested")
  func finishSkipsFinalizeWhenNoAudio() async throws {
    let backend = StubStreamingBackend()
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      backend: backend
    )
    await diarizer.finish()
    #expect(backend.finalizeCallCount == 0)
  }

  @Test("speakerId queries are counted; hits increment on actual matches")
  func speakerIdCountersWorkCorrectly() async throws {
    let backend = StubStreamingBackend()
    backend.pendingProcessUpdates = [
      StreamingDiarizerUpdate(
        finalizedSegments: [
          DiarizationSegment(speakerId: "S0", startSeconds: 0, endSeconds: 5)
        ]
      )
    ]
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 1_600,
      backend: backend
    )
    // Make process() fire so the lookup has S0 across [0, 5).
    for _ in 0..<2 {
      try await diarizer.ingest(Self.int16BufferRef(frameCount: 800))
    }
    let hit = await diarizer.speakerId(forRange: TraceAudioRange(startSeconds: 1, endSeconds: 2))
    let miss = await diarizer.speakerId(forRange: TraceAudioRange(startSeconds: 100, endSeconds: 101))
    #expect(hit == "S0")
    #expect(miss == nil)
    let queries = await diarizer.debugLookupQueryCount
    let hits = await diarizer.debugLookupHitCount
    #expect(queries == 2)
    #expect(hits == 1)
  }

  @Test("Float32 16 kHz mono buffers are also ingested (fast path 1)")
  func float32FastPathIsIngested() async throws {
    let backend = StubStreamingBackend()
    let diarizer = SortformerStreamingDiarizer(
      logTag: "test",
      processEverySamples: 16_000,
      backend: backend
    )
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let frameCount = 1024
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let dst = buffer.floatChannelData!.pointee
    for i in 0..<frameCount { dst[i] = 0.5 }
    try await diarizer.ingest(PCMBufferRef(buffer))
    #expect(backend.addAudioCalls == [frameCount])
  }
}
