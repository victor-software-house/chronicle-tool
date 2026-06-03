# Research & Design Decisions

## Summary
- **Feature**: `chronicle-menubar-app`
- **Discovery Scope**: Extension (new app target consuming existing Core/ infrastructure)
- **Key Findings**:
  - `LiveCaptureSession` actor already provides a complete start/stop/reconfigure/status API — menu bar app is just another client
  - `TranscriptionSink` protocol allows adding a UI-facing sink without modifying existing pipeline
  - All required Apple frameworks (MenuBarExtra, SMAppService, UserDefaults) are native to macOS 13+ — no external dependencies needed for the app target
  - SwiftPM library extraction is straightforward: Core/ has no imports from Subcommands/ or Chronicle.swift

## Research Log

### LiveCaptureSession as the integration surface
- **Context**: Which Core/ type should the menu bar app orchestrate?
- **Sources Consulted**: `Core/Capture/LiveCaptureSession.swift`, `Core/Capture/LiveCaptureConfiguration.swift`, existing subcommands (Mic.swift, SysAudio.swift, Live.swift)
- **Findings**:
  - `LiveCaptureSession` is an actor with `.start()`, `.stop(reason:)`, `.reconfigure(_:)`, `.status()` methods
  - Configuration is a value type specifying source, locale, output paths, audio format, diarization, rotation interval
  - Reconfiguration is gated by policy: diarization toggles apply live; locale/format changes defer to next segment
  - The three existing subcommands are thin veneers (~60 LOC) that build a configuration and call session methods
- **Implications**: CaptureManager in the app wraps LiveCaptureSession and exposes observable state. No new capture engine needed.

### Transcript pipeline for UI consumption
- **Context**: How does the app get live transcript text for the preview?
- **Sources Consulted**: `Core/Sinks/TranscriptionSink.swift`, stock sink implementations
- **Findings**:
  - `TranscriptionSink` protocol: `didReceiveResult(text:isFinal:wallclockOffsetMs:wallclock:audioRange:speakerId:)` + `finish()`
  - Sinks are composed into a pipeline via array; each result dispatched to all sinks in sequence
  - Adding a custom `UITranscriptSink` that buffers last N final lines is the natural extension
- **Implications**: No modification to existing sink dispatch needed. The app adds one more sink.

### SwiftPM library extraction feasibility
- **Context**: Can Core/ be extracted as a library target without breaking the CLI?
- **Sources Consulted**: `Package.swift`, `Chronicle.swift`, all files under `Core/` and `Subcommands/`
- **Findings**:
  - Core/ has zero imports from Subcommands/ or Chronicle.swift — clean dependency direction
  - The existing `unsafeFlags` linker settings embed Info.plist into the CLI binary — this stays on the CLI target, not the library
  - All test imports reference `@testable import Chronicle` — after split, tests targeting Core/ types would import `ChronicleCore`
- **Implications**: Library extraction requires updating Package.swift + adjusting test imports. No source file moves needed if library target points to `Sources/Chronicle/Core`.

### MenuBarExtra and app lifecycle
- **Context**: Which SwiftUI API for the menu bar presence?
- **Sources Consulted**: Apple developer documentation for `MenuBarExtra` (macOS 13+)
- **Findings**:
  - `MenuBarExtra` supports both `window` style (popover) and `menu` style (native NSMenu)
  - Menu style is simpler and matches the dropdown UX in requirements
  - Window style allows richer SwiftUI views but requires manual dismissal handling
  - On macOS 26, both styles are mature
- **Implications**: Start with menu style for simplicity. Upgrade to window style if transcript preview needs richer layout.

### Single-instance enforcement
- **Context**: How to prevent multiple app instances?
- **Sources Consulted**: macOS app lifecycle documentation
- **Findings**:
  - NSApp already prevents multiple instances for bundled .app targets launched via LaunchServices
  - For redundancy, can check `NSRunningApplication.runningApplications(withBundleIdentifier:)` at startup
  - `SMAppService.mainApp` for login item handles the case where the app is launched at login — it activates the existing instance if already running
- **Implications**: Standard macOS app behavior handles Req 9. No custom lock mechanism needed.

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks | Notes |
|--------|-------------|-----------|-------|-------|
| Direct Core/ consumption | App embeds ChronicleCore, calls LiveCaptureSession in-process | Simplest; no IPC; immediate ship | App crash kills capture | Acceptable for v1; daemon (P12) adds resilience later |
| Daemon client | App talks to separate daemon via RPC | Crash-resilient capture | Requires full P12 implementation first | Deferred per discovery brief |

## Design Decisions

### Decision: UITranscriptSink as the UI data bridge
- **Context**: The app needs live transcript lines for the preview without polling files
- **Alternatives Considered**:
  1. Poll `live.log` file periodically — simple but laggy, wasteful I/O
  2. Custom TranscriptionSink that buffers lines — in-pipeline, zero-copy path from analyzer to UI
  3. Notification/callback from LiveCaptureSession — would require modifying session API
- **Selected Approach**: Custom `UITranscriptSink` conforming to `TranscriptionSink`
- **Rationale**: Follows existing sink composition pattern exactly. No API changes to Core/. Zero additional I/O.
- **Trade-offs**: Lines are in-memory only (not persisted separately); but `FinalsAppendSink` and `JSONLTraceSink` already handle persistence.

### Decision: Menu style MenuBarExtra (not window style)
- **Context**: Requirements call for a dropdown with controls and transcript preview
- **Alternatives Considered**:
  1. Menu style (`MenuBarExtra("...", ...) { Menu content }`) — native NSMenu, lightweight
  2. Window style (`MenuBarExtra("...", ...) { Window content }`) — rich SwiftUI, heavier
- **Selected Approach**: Menu style
- **Rationale**: Requirements describe a dropdown with toggles, labels, and a text preview — all achievable with menu items. Menu style auto-dismisses on click, matches platform conventions.
- **Trade-offs**: Less layout control for transcript preview; if preview needs scrollable rich text, upgrade to window style in a future iteration.

### Decision: @Observable CaptureManager (not Combine)
- **Context**: Need reactive state for SwiftUI views
- **Alternatives Considered**:
  1. `@Observable` macro (Swift 5.9+ / macOS 14+) — native, no Combine boilerplate
  2. `ObservableObject` + `@Published` (Combine) — older pattern, more verbose
- **Selected Approach**: `@Observable` macro
- **Rationale**: macOS 26 floor means Swift 5.9+ observation is available. Simpler, less boilerplate, better SwiftUI integration.

## Risks & Mitigations
- **TCC grants may need re-granting after Xcode project changes bundle identity** — Use same bundle ID (`com.victor-software-house.chronicle`) and same team ID. Verify codesign output matches existing grants.
- **Test imports break after library extraction** — Update `@testable import Chronicle` to `@testable import ChronicleCore` for Core/ tests in the same commit.
- **MenuBarExtra menu style too limited for transcript preview** — Start with menu style; monitor UX. Upgrade to window style is a self-contained change if needed.
- **Capture blocks main actor** — `LiveCaptureSession` is an actor with async methods; capture runs on background executors. SwiftUI updates via `@Observable` cross to main actor automatically.

## References
- [MenuBarExtra — Apple Developer](https://developer.apple.com/documentation/swiftui/menubarextra) — macOS 13+ menu bar API
- [SMAppService — Apple Developer](https://developer.apple.com/documentation/servicemanagement/smappservice) — login item registration
- [Observation framework — Apple Developer](https://developer.apple.com/documentation/observation) — @Observable macro
- ADR-0001 (modular pipeline architecture) — existing Core/ protocol boundaries
- ADR-0004 (Tahoe system audio capture) — CoreAudio tap as sysaudio backend

## Verified API Surface (macOS 26 Tahoe, Xcode 26, arm64)

All findings below verified by compiling test code against the macOS 26 SDK on this machine.

### MenuBarExtra
- **Menu style** (default): content closure returns `Button`, `Toggle`, `Divider`, `Text` — native NSMenu items
- **Window style** (`.menuBarExtraStyle(.window)`): content closure returns arbitrary SwiftUI views (`VStack`, `ScrollView`, etc.)
- **Dynamic icon**: computed `systemName` in label closure updates reactively with `@Observable` state
- **@Observable**: `@State private var manager = CaptureManager()` with `@Observable` class works — no need for `ObservableObject`
- **Bindable**: `Bindable(settings).diarizationEnabled` produces `Binding<Bool>` for `Toggle`
- **No AppDelegate needed**: pure SwiftUI `@main struct App` with `MenuBarExtra` scene suffices
- **Window style chosen over menu style**: transcript preview needs `ScrollView` + rich layout; menu style limited to menu items

### SMAppService
- `SMAppService.mainApp` — static property, no allocation
- `.register()` — synchronous, throws on failure
- `.unregister()` — synchronous, throws on failure
- `.status` — returns `SMAppService.Status` enum: `.notRegistered`, `.enabled`, `.requiresApproval`, `.notFound`
- Login item state persists across app quits and reboots via LaunchServices

### TCC and Signing
- **Microphone**: auto-prompt on first access when `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input` present
- **System Audio Recording**: must be manually added via System Settings → Privacy & Security → Screen & System Audio Recording (no auto-prompt for CoreAudio taps)
- **App Sandbox**: incompatible with CoreAudio process taps → app must be non-sandboxed (matches existing chronicle.app)
- **Xcode rebuilds**: CDHash changes but TCC grants keyed by `(team-id, bundle-id)` tuple — grants survive rebuilds with same signing identity
- **LSUIElement=true**: no special TCC exemption; prompts appear same as regular app
- **Existing entitlements**: only `com.apple.security.device.audio-input` (no sandbox)
- **Info.plist keys needed**: `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSSpeechRecognitionUsageDescription`, `LSUIElement=true`

### Xcode Project Structure
- Xcode app does NOT need its own Package.swift — imports root Package.swift as local package
- `File > Add Package Dependencies > Add Local` → Xcode stores relative path in `.pbxproj`
- Signing: Target → Signing & Capabilities → Team dropdown → auto-generates provisioning profile
- CLI build: `xcodebuild -project ChronicleApp.xcodeproj -scheme ChronicleApp -configuration Release build`

### Design Decision Update: Window Style (not Menu Style)
Based on verified API surface, **window style** is the right choice:
- Transcript preview needs `ScrollView` with `VStack` of `Text` items — not possible in menu style
- `Toggle` with `Bindable` works in window style
- Dynamic icon reactivity works with both styles
- Window style auto-dismisses on focus loss (no manual handling needed)

Full prototype (CaptureManager + AppSettings + ChronicleApp + MenuBarContent) compiled clean against macOS 26 SDK.