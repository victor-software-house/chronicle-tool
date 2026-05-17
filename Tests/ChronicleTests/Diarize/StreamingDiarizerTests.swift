import Foundation
import Testing
@testable import Chronicle

@Suite("StreamingDiarizer")
struct StreamingDiarizerTests {
  // MARK: - DiarizationTimelineLookup

  @Test("returns the speaker whose interval covers the range midpoint")
  func returnsSpeakerCoveringMidpoint() {
    let lookup = DiarizationTimelineLookup(segments: [
      DiarizationSegment(speakerId: "S0", startSeconds: 0.0, endSeconds: 2.0),
      DiarizationSegment(speakerId: "S1", startSeconds: 2.0, endSeconds: 5.0),
      DiarizationSegment(speakerId: "S0", startSeconds: 5.0, endSeconds: 7.5)
    ])
    #expect(lookup.speakerId(forRange: TraceAudioRange(startSeconds: 0.5, endSeconds: 1.5)) == "S0")
    #expect(lookup.speakerId(forRange: TraceAudioRange(startSeconds: 2.5, endSeconds: 3.5)) == "S1")
    #expect(lookup.speakerId(forRange: TraceAudioRange(startSeconds: 6.0, endSeconds: 7.0)) == "S0")
  }

  @Test("returns nil when the midpoint falls in a gap")
  func returnsNilOnGap() {
    let lookup = DiarizationTimelineLookup(segments: [
      DiarizationSegment(speakerId: "S0", startSeconds: 0.0, endSeconds: 1.0),
      DiarizationSegment(speakerId: "S1", startSeconds: 3.0, endSeconds: 5.0)
    ])
    // Midpoint = 2.0, lies in the gap [1.0, 3.0).
    let result = lookup.speakerId(forRange: TraceAudioRange(startSeconds: 1.5, endSeconds: 2.5))
    #expect(result == nil)
  }

  @Test("treats endSeconds as exclusive at boundaries")
  func endSecondsIsExclusiveAtBoundary() {
    let lookup = DiarizationTimelineLookup(segments: [
      DiarizationSegment(speakerId: "S0", startSeconds: 0.0, endSeconds: 2.0),
      DiarizationSegment(speakerId: "S1", startSeconds: 2.0, endSeconds: 4.0)
    ])
    // Range midpoint == 2.0; first segment ends at 2.0 exclusive → S1.
    let result = lookup.speakerId(forRange: TraceAudioRange(startSeconds: 1.5, endSeconds: 2.5))
    #expect(result == "S1")
  }

  @Test("empty timeline always returns nil")
  func emptyTimelineReturnsNil() {
    let lookup = DiarizationTimelineLookup(segments: [])
    let result = lookup.speakerId(forRange: TraceAudioRange(startSeconds: 0.0, endSeconds: 10.0))
    #expect(result == nil)
  }

  @Test("sorts unsorted segments by start time")
  func sortsByStartTime() {
    let lookup = DiarizationTimelineLookup(segments: [
      DiarizationSegment(speakerId: "S1", startSeconds: 5.0, endSeconds: 6.0),
      DiarizationSegment(speakerId: "S0", startSeconds: 0.0, endSeconds: 2.0),
      DiarizationSegment(speakerId: "S2", startSeconds: 6.0, endSeconds: 8.0)
    ])
    #expect(lookup.segments.map(\.speakerId) == ["S0", "S1", "S2"])
  }

  @Test("speakerId(at:) returns nil at exact end boundary and start boundary returns start speaker")
  func startAndEndBoundaries() {
    let lookup = DiarizationTimelineLookup(segments: [
      DiarizationSegment(speakerId: "S0", startSeconds: 0.0, endSeconds: 1.0)
    ])
    #expect(lookup.speakerId(at: 0.0) == "S0")
    #expect(lookup.speakerId(at: 0.999) == "S0")
    #expect(lookup.speakerId(at: 1.0) == nil)
  }

  @Test("overlapping segments pick the first segment whose interval covers the time")
  func overlappingSegmentsPickFirst() {
    let lookup = DiarizationTimelineLookup(segments: [
      DiarizationSegment(speakerId: "S0", startSeconds: 0.0, endSeconds: 5.0),
      DiarizationSegment(speakerId: "S1", startSeconds: 2.0, endSeconds: 3.0)
    ])
    // Both segments cover t=2.5; sort puts S0 (start 0) first so first match wins.
    #expect(lookup.speakerId(at: 2.5) == "S0")
  }
}
