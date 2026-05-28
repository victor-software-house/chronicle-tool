import Foundation

public struct ClipRequest: Equatable, Sendable {
  public let lastSeconds: TimeInterval
  public let outputURL: URL

  public init(lastSeconds: TimeInterval, outputURL: URL) {
    self.lastSeconds = lastSeconds
    self.outputURL = outputURL
  }
}

public struct ClipAvailableRange: Equatable, Sendable {
  public let durationSeconds: TimeInterval

  public init(durationSeconds: TimeInterval) {
    self.durationSeconds = durationSeconds
  }
}

public struct ClipResult: Equatable, Sendable {
  public let source: CaptureSource
  public let outputURL: URL?
  public let availableRange: ClipAvailableRange?
  public let error: RPCError?
}

public struct MarkerResult: Equatable, Sendable {
  public let source: CaptureSource
  public let event: DaemonEvent?
  public let error: RPCError?
}

/// Recent-clip coordination against a rolling raw-PCM scratch directory.
///
/// Reads the scratch `format.json` manifest and contiguous `.pcm` segments
/// to compute retained duration, then delegates the bounded export to
/// `ScratchExporter`. Returns a structured `range_unavailable` error with
/// the actual retained range when the requested window exceeds it.
public enum ClipCoordinator {
  public static func availableDuration(at scratchDirectory: URL, fileManager: FileManager = .default) -> TimeInterval {
    let manifestURL = scratchDirectory.appendingPathComponent("format.json")
    guard let manifestData = try? Data(contentsOf: manifestURL) else { return 0 }
    guard let manifest = try? JSONDecoder().decode(ScratchFormatManifest.self, from: manifestData) else { return 0 }
    guard let bytesPerSample = manifest.bytesPerSample, manifest.sampleRate > 0 else { return 0 }
    let bytesPerFrame = bytesPerSample * manifest.channelCount
    guard bytesPerFrame > 0 else { return 0 }
    guard let entries = try? fileManager.contentsOfDirectory(at: scratchDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    let totalBytes = entries
      .filter { $0.pathExtension == "pcm" }
      .compactMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
      .reduce(0, +)
    let frames = Double(totalBytes / bytesPerFrame)
    return frames / manifest.sampleRate
  }

  public static func export(
    source: CaptureSource,
    scratchDirectory: URL,
    request: ClipRequest
  ) async -> ClipResult {
    let available = availableDuration(at: scratchDirectory)
    guard request.lastSeconds > 0 else {
      return ClipResult(
        source: source,
        outputURL: nil,
        availableRange: ClipAvailableRange(durationSeconds: available),
        error: RPCError(
          code: .rangeUnavailable,
          message: "Clip window must request a positive duration.",
          retriable: false,
          hint: "Request lastSeconds > 0 within retained sidecar data.",
          details: ["available_seconds": .number(available)]
        )
      )
    }
    guard available >= request.lastSeconds else {
      return ClipResult(
        source: source,
        outputURL: nil,
        availableRange: ClipAvailableRange(durationSeconds: available),
        error: RPCError(
          code: .rangeUnavailable,
          message: "Requested clip window exceeds retained scratch.",
          retriable: false,
          hint: "Request a window at or below the available retained range.",
          details: [
            "available_seconds": .number(available),
            "requested_seconds": .number(request.lastSeconds),
          ]
        )
      )
    }
    do {
      _ = try await ScratchExporter.export(
        scratchDirectory: scratchDirectory,
        outputURL: request.outputURL
      )
      return ClipResult(
        source: source,
        outputURL: request.outputURL,
        availableRange: ClipAvailableRange(durationSeconds: available),
        error: nil
      )
    } catch {
      return ClipResult(
        source: source,
        outputURL: nil,
        availableRange: ClipAvailableRange(durationSeconds: available),
        error: RPCError(
          code: .rangeUnavailable,
          message: "Scratch export failed: \(error.localizedDescription)",
          retriable: false,
          hint: "Inspect the scratch directory manifest and segment files.",
          details: ["available_seconds": .number(available)]
        )
      )
    }
  }
}
