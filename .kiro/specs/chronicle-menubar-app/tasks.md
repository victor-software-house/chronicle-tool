# Implementation Plan

- [x] 1. Extract ChronicleCore library target from Package.swift
- [x] 1.1 Add a library product and target for ChronicleCore pointing at `Sources/Chronicle/Core`; update the Chronicle executable target to depend on ChronicleCore and exclude `Core/` from its own source paths
  - The existing `unsafeFlags` linker settings for Info.plist embedding stay on the CLI target only
  - `swift build` produces both the CLI executable and the ChronicleCore library without errors
  - `swift test` passes all 108+ existing tests (update `@testable import Chronicle` to `@testable import ChronicleCore` for Core-targeting tests)
  - _Requirements: 10_
  - _Boundary: Package.swift, Tests/ChronicleTests_

- [x] 2. Create Xcode macOS app project with MenuBarExtra skeleton
- [x] 2.1 Create the `ChronicleApp/` directory with Xcode project, SwiftUI App entry point, Info.plist, entitlements, and asset catalog
  - Info.plist includes `LSUIElement=true`, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSSpeechRecognitionUsageDescription`, bundle ID `com.victor-software-house.chronicle`
  - Entitlements include `com.apple.security.device.audio-input`; no App Sandbox (CoreAudio taps incompatible)
  - Xcode project references root `Package.swift` as a local Swift package and links `ChronicleCore`
  - Automatic signing configured with team ID CXLYTY8DMR
  - The app builds from Xcode, launches, and shows a static menu bar icon with a placeholder dropdown
  - No dock icon appears (LSUIElement agent app)
  - `xcodebuild -project ChronicleApp/ChronicleApp.xcodeproj -scheme ChronicleApp build` succeeds from CLI
  - _Depends: 1.1_
  - _Requirements: 1, 11_
  - _Boundary: ChronicleApp_

- [ ] 3. Implement core app state and settings
- [x] 3.1 (P) Implement CaptureState enum and TranscriptLine value type
  - `CaptureState` with cases `idle`, `recording(sources: Set<CaptureSource>)`, `error(message: String)`
  - `CaptureSource` enum with `mic` and `sysaudio` cases
  - `TranscriptLine` with `id: UUID`, `text: String`, `speakerId: String?`, `timestamp: Date`
  - Types compile and are importable from the Views layer
  - _Requirements: 1, 2_
  - _Boundary: ChronicleApp/Core/CaptureState, ChronicleApp/Core/TranscriptLine_

- [x] 3.2 (P) Implement AppSettings with UserDefaults persistence and SMAppService login item
  - `@Observable` class with `diarizationEnabled` and `launchAtLogin` properties persisted to UserDefaults
  - `launchAtLogin` setter calls `SMAppService.mainApp.register()` / `.unregister()` and handles errors gracefully
  - Init reads current state from UserDefaults and syncs `launchAtLogin` with `SMAppService.mainApp.status`
  - Round-trip persistence verified: set value, reinitialize, value preserved
  - _Requirements: 3, 7_
  - _Boundary: ChronicleApp/Core/AppSettings_

- [x] 4. Implement UITranscriptSink
- [x] 4.1 Implement TranscriptionSink conformance that buffers last N final transcript lines for UI consumption
  - Conforms to `TranscriptionSink` protocol from ChronicleCore
  - Buffers last 50 final results as `TranscriptLine` values (configurable capacity)
  - Tracks distinct speaker IDs and exposes `speakerCount`
  - `finish()` is callable and does not clear lines (preserves last session's transcript for review)
  - Thread-safe: sink methods called from background capture tasks; UI reads from main actor via `@Observable`
  - Unit test verifies capacity bounds, speaker counting, and final-only filtering
  - _Depends: 1.1_
  - _Requirements: 4_
  - _Boundary: ChronicleApp/Sinks/UITranscriptSink_

- [x] 5. Implement CaptureManager
- [x] 5.1 Implement the @Observable actor that wraps LiveCaptureSession and bridges capture lifecycle to SwiftUI state
  - `startCapture(sources:)` builds a `LiveCaptureConfiguration` from `AppSettings`, injects `UITranscriptSink` alongside stock sinks, creates and starts a `LiveCaptureSession`; transitions state to `.recording`
  - `stopCapture()` calls `LiveCaptureSession.stop(reason: .clientRequest)`, waits for finalization, transitions to `.idle`
  - `toggleDiarization()` calls `LiveCaptureSession.reconfigure()` when active, or updates `AppSettings` when idle
  - `shutdown()` stops any active capture (bounded by existing L3 timeout defense) before returning
  - Exposes observable `state`, `transcriptLines` (from UITranscriptSink), `sessionDuration`, `speakerCount`, `activeSources`, `sessionOutputURL`
  - Session duration updates via a timer while recording
  - Error from `LiveCaptureSession.start()` (TCC denial, audio source failure) transitions to `.error(message:)` with remediation text
  - `startCapture` while already recording is a no-op; `stopCapture` while idle is a no-op
  - _Depends: 3.1, 3.2, 4.1_
  - _Requirements: 2, 3, 4, 5, 8_
  - _Boundary: ChronicleApp/Core/CaptureManager_

- [x] 6. Implement menu bar UI views
- [x] 6.1 Implement MenuBarView as the window-style dropdown content
  - Start buttons for mic, sysaudio, and both; stop button per source when recording
  - Diarization toggle bound to `AppSettings.diarizationEnabled` via `Bindable`
  - Embeds `TranscriptPreview` and `SessionInfoView`
  - Open session folder button calls `NSWorkspace.shared.selectFile` on `CaptureManager.sessionOutputURL`
  - Launch-at-login toggle bound to `AppSettings.launchAtLogin`
  - Quit button calls `CaptureManager.shutdown()` then `NSApp.terminate(nil)`
  - Error state displays the error message from `CaptureState.error`
  - _Depends: 5.1_
  - _Requirements: 1, 2, 3, 6, 7, 8_
  - _Boundary: ChronicleApp/Views/MenuBarView_

- [x] 6.2 (P) Implement TranscriptPreview showing last N transcript lines with speaker labels
  - ScrollView with VStack of Text items from `CaptureManager.transcriptLines`
  - Speaker labels rendered as `[S0]` prefix when present
  - Shows "No active session" placeholder when `transcriptLines` is empty and state is idle
  - _Depends: 5.1_
  - _Requirements: 4_
  - _Boundary: ChronicleApp/Views/TranscriptPreview_

- [x] 6.3 (P) Implement SessionInfoView showing duration, sources, and speaker count
  - Elapsed duration formatted as `HH:MM:SS` from `CaptureManager.sessionDuration`
  - Active sources listed (mic, sysaudio, or both)
  - Speaker count displayed when diarization is enabled and speakers detected
  - Hidden when no capture session is active
  - _Depends: 5.1_
  - _Requirements: 5_
  - _Boundary: ChronicleApp/Views/SessionInfoView_

- [x] 7. Wire ChronicleApp entry point and single-instance enforcement
- [x] 7.1 Wire the @main App struct with MenuBarExtra scene, dynamic icon, and single-instance guard
  - `@main struct ChronicleApp: App` with `MenuBarExtra` using `.menuBarExtraStyle(.window)`
  - Label uses computed SF Symbol name: `waveform` (idle), `record.circle.fill` (recording), `exclamationmark.triangle.fill` (error)
  - `@State` properties for `CaptureManager` and `AppSettings` injected into `MenuBarView`
  - Single-instance check in `init()`: `NSRunningApplication.runningApplications(withBundleIdentifier:)` — if already running, activate existing and `NSApp.terminate(nil)`
  - App termination observer calls `CaptureManager.shutdown()` before exit
  - Launching the app shows the menu bar icon; clicking it opens the dropdown; the app has no dock icon
  - Launching ChronicleApp a second time while already running activates the existing instance and terminates the second without error
  - _Depends: 6.1_
  - _Requirements: 1, 8, 9_
  - _Boundary: ChronicleApp/ChronicleApp.swift_

- [ ] 8. Integration verification
- [ ] 8.1 Verify CLI continuity after library extraction
  - `swift build` from repo root succeeds
  - `swift test` passes all existing tests
  - `.build/debug/chronicle --help` shows all 16 subcommands
  - `.build/debug/chronicle transcribe --help` runs without error
  - _Depends: 1.1_
  - _Requirements: 10_
  - _Boundary: Package.swift, Sources/Chronicle_

- [ ] 8.2 Verify Xcode app build, signing, and TCC grant flow
  - Build from Xcode succeeds with automatic signing (team CXLYTY8DMR)
  - `codesign -dvv` on built app shows correct bundle ID, team ID, Info.plist bound, audio-input entitlement
  - Install to `/Applications/ChronicleApp.app` (or confirm existing TCC grants transfer if using same bundle ID)
  - Grant Microphone and Screen & System Audio Recording in System Settings
  - Rebuild from Xcode → existing TCC grants remain valid
  - _Depends: 7.1_
  - _Requirements: 11_
  - _Boundary: ChronicleApp_

- [ ] 8.3 End-to-end smoke: start mic capture from menu bar, verify transcript in dropdown
  - Launch ChronicleApp, click menu bar icon, click Start Mic
  - Speak into microphone or play audio; transcript lines appear in the dropdown preview
  - Click Stop; capture finalizes; `finals.md` and `trace.jsonl` exist in session output directory
  - Open session folder button reveals the correct directory in Finder
  - _Depends: 8.2_
  - _Requirements: 2, 4, 6_

- [ ] 8.4 End-to-end smoke: start sysaudio with diarization, verify speaker labels
  - Enable diarization toggle, click Start Sysaudio
  - Play multi-speaker audio (TTS fixture or podcast); transcript lines show `[S0]`/`[S1]` prefixes
  - Speaker count in session info increments as new speakers are detected
  - Stop capture; verify speaker labels in `finals.md`
  - _Depends: 8.2_
  - _Requirements: 2, 3, 4, 5_

- [ ] 8.5 Verify clean shutdown and launch-at-login
  - Start a capture session, then quit ChronicleApp via the dropdown
  - `finals.md` and `trace.jsonl` are complete (finalization succeeded)
  - Enable launch-at-login toggle; log out and log in; ChronicleApp appears in the menu bar without manual launch
  - Disable launch-at-login; reboot; ChronicleApp does not start
  - _Depends: 8.2_
  - _Requirements: 7, 8_

- [ ] 9. Update project documentation
- [ ] 9.1 Update README, AGENTS.md, and docs/STATUS.md to reflect the menu bar app
  - README.md documents the Xcode build and launch workflow, TCC grant for the app, and removes `make-app.sh` as the primary live capture path
  - AGENTS.md adds "Build menu bar app from Xcode" section and documents the dual build system (SwiftPM CLI + Xcode app)
  - docs/STATUS.md adds the menu bar app phase as delivered
  - _Depends: 8.2_
  - _Requirements: 11_
  - _Boundary: README.md, AGENTS.md, docs/STATUS.md_

## Implementation Notes
- **No external deps for ChronicleApp target** — evaluated Apple Swift Packages (swift-algorithms, swift-async-algorithms, swift-collections, swift-atomics, swift-system, swift-nio). None needed. App uses only ChronicleCore (local) + Apple system frameworks. `swift-async-algorithms` (debounce/throttle) is the only candidate worth revisiting if transcript update performance becomes an issue.
