import Foundation
import Testing
@testable import ChronicleCore

@Suite("Marker and clip coordination")
struct MarkerClipCoordinatorTests {
  @Test("active marker creates timestamped control event")
  func activeMarkerCreatesTimestampedControlEvent() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .mic, rootDirectory: try temporaryRoot()), configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure"))

    let result = await coordinator.createMarker(label: "interesting", clientRequestID: ClientRequestID(rawValue: "mark-1"))

    #expect(result.error == nil)
    #expect(result.event?.type == "marker.created")
    #expect(result.event?.payload["label"] == .string("interesting"))
    #expect(result.event?.source == .mic)
  }

  @Test("marker with no active session reports no active session")
  func markerWithNoActiveSessionReportsNoActiveSession() async throws {
    let coordinator = DaemonCoordinator(paths: RuntimePaths(source: .sysaudio, rootDirectory: try temporaryRoot()), configuration: .direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))

    let result = await coordinator.createMarker(label: "miss", clientRequestID: ClientRequestID(rawValue: "mark-2"))

    #expect(result.event == nil)
    #expect(result.error?.code == .noActiveSession)
    #expect(result.error?.retriable == false)
  }

  @Test("available clip request exports bounded scratch and releases lease")
  func availableClipRequestExportsBoundedScratchAndReleasesLease() async throws {
    let root = try temporaryRoot()
    let paths = RuntimePaths(source: .mic, rootDirectory: root)
    try makeScratch(at: paths.sourceDirectory.appendingPathComponent("scratch", isDirectory: true), frames: 16_000)
    let coordinator = DaemonCoordinator(paths: paths, configuration: .direct(source: .mic, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure"))
    let output = root.appendingPathComponent("clip.wav")

    let result = await coordinator.createClip(request: ClipRequest(lastSeconds: 0.5, outputURL: output), clientRequestID: ClientRequestID(rawValue: "clip-1"))

    #expect(result.error == nil)
    #expect(result.outputURL == output)
    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(await coordinator.activeCoordinationLeases().isEmpty)
  }

  @Test("unavailable clip range reports available range and releases lease")
  func unavailableClipRangeReportsAvailableRangeAndReleasesLease() async throws {
    let root = try temporaryRoot()
    let paths = RuntimePaths(source: .sysaudio, rootDirectory: root)
    try makeScratch(at: paths.sourceDirectory.appendingPathComponent("scratch", isDirectory: true), frames: 4_000)
    let coordinator = DaemonCoordinator(paths: paths, configuration: .direct(source: .sysaudio, locale: "auto", output: nil, append: nil, live: nil, saveAudio: nil, audioFormat: "alac", diarize: false))
    _ = try await coordinator.ensure(clientRequestID: ClientRequestID(rawValue: "ensure"))

    let result = await coordinator.createClip(request: ClipRequest(lastSeconds: 5, outputURL: root.appendingPathComponent("too-long.wav")), clientRequestID: ClientRequestID(rawValue: "clip-2"))

    #expect(result.outputURL == nil)
    #expect(result.error?.code == .rangeUnavailable)
    #expect(result.availableRange?.durationSeconds ?? 0 > 0)
    #expect(await coordinator.activeCoordinationLeases().isEmpty)
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cmclip-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeScratch(at directory: URL, frames: Int) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = """
    {"sampleRate":16000,"channelCount":1,"commonFormat":"float32","interleaved":true,"bitsPerChannel":32,"ttl":300,"rotateInterval":30}
    """
    try Data(manifest.utf8).write(to: directory.appendingPathComponent("format.json"))
    var samples = [Float](repeating: 0.0, count: frames)
    samples.withUnsafeBytes { raw in
      try? Data(raw).write(to: directory.appendingPathComponent("000000.pcm"))
    }
  }
}
