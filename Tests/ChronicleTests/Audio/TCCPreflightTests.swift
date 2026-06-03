import Testing
import Foundation
@testable import ChronicleCore

@Suite("TCCPreflight")
struct TCCPreflightTests {

  @Test("microphone() returns a valid state and never blocks")
  func microphoneNonBlocking() async {
    let started = Date()
    let state = TCCPreflight.microphone()
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 0.1, "preflight should be effectively instantaneous; took \(elapsed)s")
    // Any of the three states is valid; we don't assert which.
    _ = state
  }

  @Test("microphoneRemediation message names System Settings + Microphone")
  func microphoneRemediation() {
    let msg = TCCPreflight.microphoneRemediation
    #expect(msg.contains("System Settings"))
    #expect(msg.contains("Microphone"))
  }

  @Test("systemAudioRecordingRemediation treats preflight as advisory and names signed app")
  func systemAudioRecordingRemediation() {
    let msg = TCCPreflight.systemAudioRecordingRemediation

    #expect(msg.contains("/Applications/chronicle.app"))
    #expect(msg.contains("Screen & System Audio Recording"))
    #expect(msg.contains("runtime PCM peak"))
    #expect(msg.contains("preflight check can be inconclusive"))
  }
}
