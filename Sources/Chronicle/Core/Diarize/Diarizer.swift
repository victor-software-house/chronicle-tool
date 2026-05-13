import Foundation

/// Plain-data segment result emitted by every diarizer implementation.
/// Offline VBx and the upcoming streaming Sortformer (FR-4) both produce
/// values of this shape so downstream merge / labelling code is
/// implementation-agnostic.
public struct DiarizationSegment: Codable, Sendable, Equatable {
  public let speakerId: String
  public let startSeconds: Double
  public let endSeconds: Double

  public init(speakerId: String, startSeconds: Double, endSeconds: Double) {
    self.speakerId = speakerId
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
  }
}

/// Aggregate result of one offline diarization run.
public struct DiarizationResult: Sendable {
  public let segments: [DiarizationSegment]
  public let audioDurationSeconds: Double
  public let elapsedSeconds: Double

  public var realtimeFactor: Double {
    elapsedSeconds > 0 ? audioDurationSeconds / elapsedSeconds : 0
  }
  public var speakerIds: Set<String> {
    Set(segments.map(\.speakerId))
  }
}

/// Offline-file diarization protocol. The streaming counterpart
/// (`StreamingDiarizing`) lands with FR-4.
public protocol OfflineDiarizing: Sendable {
  /// Diarize an audio file and return every segment in a single batch.
  func diarizeFile(_ url: URL) async throws -> DiarizationResult
}
