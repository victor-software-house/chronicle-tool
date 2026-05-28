import Foundation
import Testing
@testable import Chronicle

@Suite("RPC round trip against running daemon")
struct RPCRoundTripTests {
  @Test("capture lifecycle round trip: ensure → status → stop → status")
  func captureLifecycleRoundTrip() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let ensure = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-ensure-1"))
    #expect(ensure.error == nil)
    #expect(ensure.result?["lifecycle"] == .string("capturing"))

    let statusAfterEnsure = await StatusClient.fetch(paths: paths)
    #expect(statusAfterEnsure.error == nil)
    #expect(statusAfterEnsure.result?["lifecycle"] == .string("capturing"))
    // health may be either "healthy" or "idleOutput" depending on heartbeat peak/counter accumulation in mock session
    let projectedHealth = statusAfterEnsure.result?["health"]
    #expect(projectedHealth == .string("healthy") || projectedHealth == .string("idleOutput"))

    let stop = await StopClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-stop-1"))
    #expect(stop.error == nil)
    #expect(stop.result?["lifecycle"] == .string("stopped"))
    #expect(stop.result?["outcome"] == .string("graceful"))

    let statusAfterStop = await StatusClient.fetch(paths: paths)
    #expect(statusAfterStop.error == nil)
    #expect(statusAfterStop.result?["lifecycle"] == .string("stopped"))
  }

  @Test("ensure replays prior result for same client_req_id")
  func ensureReplaysPriorResultForSameClientRequestID() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let cid = ClientRequestID(rawValue: "rt-replay-1")
    let first = await StartClient.send(paths: paths, clientRequestID: cid)
    let second = await StartClient.send(paths: paths, clientRequestID: cid)

    #expect(first.error == nil)
    #expect(second.error == nil)
    #expect(first.result?["lifecycle"] == second.result?["lifecycle"])
    #expect(first.result?["status"] == second.result?["status"])
  }

  @Test("mark.create returns no_active_session when capture is stopped")
  func markCreateReturnsNoActiveSessionWhenCaptureStopped() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let response = await MarkClient.send(
      paths: paths,
      label: "anchor",
      clientRequestID: ClientRequestID(rawValue: "rt-mark-1")
    )

    #expect(response.error?.code == .noActiveSession)
    #expect(response.error?.retriable == false)
  }

  @Test("mark.create after ensure produces a marker.created event in the result")
  func markCreateAfterEnsureProducesMarkerCreatedEvent() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    _ = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-mark-ensure"))
    let response = await MarkClient.send(
      paths: paths,
      label: "anchor",
      clientRequestID: ClientRequestID(rawValue: "rt-mark-2")
    )

    #expect(response.error == nil)
    #expect(response.result?["source"] == .string("mic"))
    if case .object(let event)? = response.result?["event"] {
      #expect(event["type"] == .string("marker.created"))
      if case .object(let payload)? = event["payload"] {
        #expect(payload["label"] == .string("anchor"))
      } else {
        Issue.record("marker event missing payload object")
      }
    } else {
      Issue.record("mark result missing event object")
    }
  }

  @Test("mark.create persists marker.created to durable DaemonEventLog")
  func markCreatePersistsMarkerCreatedToDurableEventLog() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    _ = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-mark-persist-ensure"))
    let response = await MarkClient.send(
      paths: paths,
      label: "persist",
      clientRequestID: ClientRequestID(rawValue: "rt-mark-persist-1")
    )
    #expect(response.error == nil)

    let events = try DaemonEventLog.read(url: paths.logURL)
    let markerEvents = events.filter { $0.type == "marker.created" }
    #expect(!markerEvents.isEmpty)
    #expect(markerEvents.first?.payload["label"] == .string("persist"))
  }

  @Test("events.subscribe returns marker.created after mark.create")
  func eventsSubscribeReturnsMarkerCreatedAfterMarkCreate() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    _ = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-sub-ensure"))
    _ = await MarkClient.send(
      paths: paths,
      label: "subscribed",
      clientRequestID: ClientRequestID(rawValue: "rt-sub-mark")
    )
    let response = await TailClient.send(
      paths: paths,
      request: TailRequest(source: .mic, typePrefix: "marker.")
    )

    #expect(response.error == nil)
    if case .array(let arr)? = response.result?["events"] {
      let labels = arr.compactMap { value -> String? in
        if case .object(let obj) = value, case .object(let payload)? = obj["payload"], case .string(let label)? = payload["label"] {
          return label
        }
        return nil
      }
      #expect(labels.contains("subscribed"))
    } else {
      Issue.record("events.subscribe result missing events array")
    }
  }

  @Test("heartbeat emitter publishes heartbeat events while capturing")
  func heartbeatEmitterPublishesHeartbeatEventsWhileCapturing() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    _ = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-hb-ensure"))
    await daemon.coordinator.startHeartbeats(interval: 0.05)
    try await Task.sleep(nanoseconds: 250_000_000)

    let response = await TailClient.send(
      paths: paths,
      request: TailRequest(source: .mic, streams: [.heartbeat])
    )

    #expect(response.error == nil)
    if case .array(let arr)? = response.result?["events"] {
      let heartbeats = arr.filter { value -> Bool in
        if case .object(let obj) = value, case .string(let type)? = obj["type"] { return type == "heartbeat" }
        return false
      }
      #expect(!heartbeats.isEmpty)
    } else {
      Issue.record("events.subscribe heartbeat result missing events array")
    }
  }

  @Test("idempotent mark.create replays prior response across daemon restart")
  func idempotentMarkCreateReplaysPriorResponseAcrossDaemonRestart() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let cid = ClientRequestID(rawValue: "rt-idem-restart-1")

    do {
      let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
      try await daemon.start()
      _ = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-idem-restart-ensure"))
      let first = await MarkClient.send(paths: paths, label: "durable-replay", clientRequestID: cid)
      #expect(first.error == nil)
      await daemon.stop()
    }

    let restarted = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await restarted.start()
    defer { Task { await restarted.stop() } }

    let replay = await MarkClient.send(paths: paths, label: "durable-replay", clientRequestID: cid)
    #expect(replay.error == nil)
    if case .object(let event)? = replay.result?["event"], case .object(let payload)? = event["payload"], case .string(let label)? = payload["label"] {
      #expect(label == "durable-replay")
    } else {
      Issue.record("replayed mark.create result missing event payload label")
    }

    // The replay must not produce a duplicate marker.created entry in the
    // durable JSONL: persisted IdempotencyStore intercepts the request before
    // the coordinator records a second event.
    let events = try DaemonEventLog.read(url: paths.logURL)
    let markers = events.filter { $0.type == "marker.created" }
    #expect(markers.count == 1)
  }

  @Test("clip.create returns range_unavailable when no scratch exists")
  func clipCreateReturnsRangeUnavailableWhenNoScratchExists() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    let outputURL = paths.sourceDirectory.appendingPathComponent("clip.caf")
    let response = await ClipClient.send(
      paths: paths,
      request: ClipRequest(lastSeconds: 5, outputURL: outputURL),
      clientRequestID: ClientRequestID(rawValue: "rt-clip-1")
    )

    #expect(response.error?.code == .rangeUnavailable)
    #expect(response.error?.retriable == false)
  }

  @Test("capture.reconfigure applies setDiarization and emits status update")
  func captureReconfigureAppliesSetDiarizationAndEmitsStatusUpdate() async throws {
    let paths = RuntimePaths(source: .mic, rootDirectory: try temporaryRoot())
    let daemon = Daemon(paths: paths, configuration: directConfig(paths: paths))
    try await daemon.start()
    defer { Task { await daemon.stop() } }

    _ = await StartClient.send(paths: paths, clientRequestID: ClientRequestID(rawValue: "rt-reconfig-ensure"))
    let response = await ConfigClient.send(
      paths: paths,
      change: .setDiarization(enabled: true),
      clientRequestID: ClientRequestID(rawValue: "rt-reconfig-1")
    )

    #expect(response.error == nil)
    #expect(response.result?["source"] == .string("mic"))
    #expect(response.result?["outcome"] == .string("applied_live"))
  }

  private func directConfig(paths: RuntimePaths) -> LiveCaptureConfiguration {
    .direct(source: paths.source, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false)
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("crrt-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
