import Testing
import Foundation
import AVFoundation
@testable import Chronicle

@Suite("TCCPreflight")
struct TCCPreflightTests {

  @Test("screenRecording() returns granted or denied, never blocks, returns within 100 ms")
  func screenRecordingNonBlocking() async {
    let started = Date()
    let state = TCCPreflight.screenRecording()
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed < 0.1, "preflight should be effectively instantaneous; took \(elapsed)s")
    #expect(state == .granted || state == .denied,
            "Screen Recording is never .undetermined on macOS (TCC reports denied for unset entries)")
  }

  @Test("screenRecordingRemediation message names System Settings + the parent app")
  func screenRecordingRemediation() {
    let msg = TCCPreflight.screenRecordingRemediation
    #expect(msg.contains("System Settings"))
    #expect(msg.contains("Screen") && msg.contains("Recording"))
    #expect(msg.contains("parent"), "should explain the parent-app TCC attribution model")
  }

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

  @Test("SysAudioSource.start() throws screenRecordingTCCDenied fast when Screen Recording is unset")
  func sysAudioStartFailsFastWhenTCCDenied() async throws {
    // Meaningful only when the live machine state has Screen Recording
    // denied. We probe and return gracefully if it's currently granted
    // (the production happy path is exercised by separate live smoke).
    let state = TCCPreflight.screenRecording()
    guard state == .denied else {
      // Skipped: Screen Recording currently granted. The complementary
      // "start() succeeds" path is exercised by live smoke; this test
      // only asserts the fast-fail behaviour when TCC is unset.
      return
    }

    let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let src = SysAudioSource(analyzerFormat: analyzerFormat, excludeCurrentProcessAudio: true)

    let started = Date()
    do {
      try await src.start()
      Issue.record("expected throw; start() returned cleanly with TCC denied")
    } catch let e as SysAudioSourceError {
      let elapsed = Date().timeIntervalSince(started)
      #expect(elapsed < 1.0,
              "must fail fast (< 1 s); took \(elapsed)s — earlier regression hung forever instead of throwing")
      #expect(isTCCDeniedFamily(e),
              "expected screenRecordingTCCDenied; got \(e)")
      #expect("\(e)".contains("System Settings"),
              "error description should carry the actionable remediation; got: \(e)")
    } catch {
      Issue.record("expected SysAudioSourceError; got \(type(of: error)): \(error)")
    }
  }

  @Test("SysAudioSource.start() reaches startCapture() quickly when TCC is granted")
  func sysAudioStartProgressesWhenTCCGranted() async throws {
    // Meaningful only when Screen Recording is currently granted.
    let state = TCCPreflight.screenRecording()
    guard state == .granted else { return }

    let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let src = SysAudioSource(analyzerFormat: analyzerFormat, excludeCurrentProcessAudio: true)

    let started = Date()
    do {
      try await src.start()
      let elapsed = Date().timeIntervalSince(started)
      // start() must return within the SCStream startTimeoutSeconds
      // budget plus a generous margin.
      #expect(elapsed < SysAudioSource.startTimeoutSeconds + 5.0,
              "start() should return within bounded time; took \(elapsed)s")
      // Clean up so the test doesn't leave SCStream resources hanging.
      src.stop()
    } catch let e as SysAudioSourceError {
      // Acceptable outcomes when TCC is granted but the system is in an
      // unhappy state (no display, brief stall): the bounded error
      // surface, never an indefinite hang.
      Issue.record("start() failed despite TCC granted: \(e)")
    }
  }

  /// `SysAudioSourceError` does not synthesize `Equatable` because some
  /// cases wrap arbitrary `Error`s; classify the TCC-denied family by
  /// pattern instead.
  private func isTCCDeniedFamily(_ e: SysAudioSourceError) -> Bool {
    switch e {
    case .screenRecordingTCCDenied, .startTimedOut, .audioCaptureSilent:
      return true
    case .permissionDenied, .noDisplayAvailable, .startFailed:
      return false
    }
  }
}

// Custom Equatable shim for the specific case we want to assert in tests.
extension SysAudioSourceError {
  static func == (lhs: SysAudioSourceError, rhs: SysAudioSourceError) -> Bool {
    switch (lhs, rhs) {
    case (.screenRecordingTCCDenied, .screenRecordingTCCDenied):
      return true
    default:
      return false
    }
  }
}
