# Brief: chronicle-menubar-app

## Problem

Chronicle is a powerful local-first audio capture + transcription + diarization toolkit, but it's CLI-only. Starting a live capture session requires typing long commands into a terminal (`/Applications/chronicle.app/Contents/MacOS/chronicle mic --diarize ...`). There's no persistent UI presence, no quick toggle for recording, no way to see live transcript output without tailing a file. The `make-app.sh` shell script that wraps `swift build` + `codesign` + `cp` into an `.app` bundle is a brittle workaround for TCC identity — not a real app.

For a tool meant to run during meetings and work sessions, the operator should be able to start/stop capture from the menu bar in two clicks.

## Current State

- **Build:** Pure SwiftPM (`swift-tools-version: 6.2`, macOS 26). No Xcode project.
- **App bundle:** Shell script `scripts/make-app.sh` builds release binary, assembles `.app` bundle, codesigns with Apple Development identity, copies to `/Applications/`. Fragile; CDHash changes invalidate TCC grants on ad-hoc builds.
- **Runtime:** CLI executable only. Live capture via `chronicle mic` / `chronicle sysaudio` / `chronicle live` run in the foreground of a terminal.
- **Architecture:** ~70 Swift files. Protocol-oriented `Core/` (Audio, Speech, Diarize, LLM, Sinks, Runtime, Daemon, Capture) + thin `Subcommands/` veneers. Well-factored for reuse.
- **Daemon infra:** `Core/Daemon/` has scaffolded JSON-RPC, Unix socket transport, coordinator, leases, idempotency — but not wired for production yet (P12 spec).
- **Tests:** 108+ via Swift Testing.
- **Signing:** Apple Development (Team ID CXLYTY8DMR), bundle ID `com.victor-software-house.chronicle`.

## Desired Outcome

Chronicle lives in the macOS menu bar as a proper `.app`. The operator can:

1. See a status icon indicating idle / recording / error state.
2. Click the icon to get a dropdown with capture controls.
3. Start/stop mic and/or sysaudio capture with diarization toggle — two clicks.
4. See a live transcript preview in the dropdown (last N lines with speaker labels).
5. View current session info (duration, speaker count, source).
6. Open the current session folder in Finder.
7. Optionally launch at login (persists across reboots).
8. Quit the app cleanly (finalizes any active capture).

The CLI continues to work for offline subcommands (`transcribe`, `diarize`, `merge`, etc.) via `swift build`. The menu bar app is the production path for live capture — it replaces `make-app.sh` as the way to get a properly signed, TCC-registered app bundle.

## Approach

**Xcode App + SwiftPM Local Package (Approach A):**

1. Extract `Core/` as a SwiftPM library product (`ChronicleCore`) in the existing `Package.swift`.
2. Create a new Xcode macOS app project (`ChronicleApp/`) that imports `ChronicleCore` as a local Swift package dependency.
3. The app uses SwiftUI `MenuBarExtra` (native macOS 13+) for the menu bar presence.
4. Xcode handles signing, entitlements, asset catalog, and app lifecycle natively.
5. The CLI remains pure SwiftPM (`swift build && swift test`).
6. `make-app.sh` is retired — the Xcode-built app IS the production artifact.

**Daemon strategy (phased):** The menu bar app captures in-process via `Core/` directly for now. It is designed from the start as the future daemon host (single-instance enforcement, proper lifecycle). When the daemon control plane (P12) lands, the app adds Unix socket RPC server and CLI becomes a thin client. The app IS the daemon — same pattern as Docker Desktop, Tailscale, 1Password.

## Scope

- **In**:
  - Extract `ChronicleCore` library target from existing `Core/`
  - Xcode macOS app project with `MenuBarExtra`
  - Proper app signing, entitlements, Info.plist (Xcode-native)
  - Start/stop controls for mic, sysaudio, or both
  - Diarization on/off toggle
  - Live transcript preview (scrolling last N lines with speaker labels)
  - Session info display (duration, speakers, source)
  - Open session folder in Finder
  - Login item via `SMAppService`
  - Status icon states (idle, recording, error)
  - Clean quit with capture finalization
  - Retire `make-app.sh` for live capture use
  - Update README, AGENTS.md, docs/STATUS.md

- **Out**:
  - Daemon RPC server / Unix socket (deferred to P12 update)
  - CLI-to-app RPC client wiring (deferred to P12)
  - Floating transcript overlay window (stretch goal, not this spec)
  - Offline subcommand UI (transcribe, diarize, merge stay CLI-only)
  - App Store distribution / notarization (local-only app)
  - System tray notifications beyond status icon
  - Audio source selection UI (follows default output automatically per existing design)
  - Locale/language selection UI (use `--locale` pin behavior, hardcode or use system locale)

## Boundary Candidates

- **ChronicleCore library vs CLI target:** Core/ becomes a shared library; Subcommands/ stays CLI-only. Clean protocol boundary already exists.
- **App UI vs capture engine:** The app's SwiftUI layer calls into `Core/` protocols (AudioSource, TranscriptionSink, StreamingDiarizer). No capture logic in the UI layer.
- **App lifecycle vs capture lifecycle:** Single-instance app process manages capture sessions. Capture start/stop is independent of app window visibility.
- **Build system boundary:** SwiftPM owns the library + CLI. Xcode owns the app. They share `ChronicleCore` via local package dependency.

## Out of Boundary

- The daemon control plane (P12 / `agent-safe-capture-daemon-control-plane` spec) — the RPC layer, leases, idempotency, agent subscribe API. This spec builds the host process; P12 adds the RPC surface.
- Audio format decisions — ALAC default, scratch PCM, Opus export all stay as-is (ADR-0002/ADR-0005).
- Locale auto-detect (P4) — broken NLLanguageRecognizer, pinned via `--locale`. Not adding UI for this.
- Live tagging (P6) — `ContentTagger` via `--tag-every`. Not adding UI for this.

## Upstream / Downstream

- **Upstream**:
  - `Core/Audio/` — `AudioSource` protocol, `MicAudioSource`, `CoreAudioTapSource` (existing, consumed as-is)
  - `Core/Speech/` — `TranscriptionEngine` / `SpeechAnalyzer` (existing)
  - `Core/Diarize/` — `StreamingDiarizer` / Sortformer (existing)
  - `Core/Sinks/` — `TranscriptionSink` protocol family (existing)
  - `Core/Capture/` — `LiveCaptureSession`, `LiveCaptureConfiguration` (existing)
  - Apple frameworks: SwiftUI, AppKit (NSStatusItem fallback if needed), ServiceManagement (SMAppService)

- **Downstream**:
  - `agent-safe-capture-daemon-control-plane` (P12) — will add RPC server to this app process
  - Future floating transcript overlay — would attach to this app's capture state
  - Future notification/summary features — would hook into this app's session lifecycle

## Existing Spec Touchpoints

- **Extends**: None directly — this is a new boundary.
- **Adjacent**: `agent-safe-capture-daemon-control-plane` — the menu bar app is designed as the future daemon host. P12's spec may need a small update to note "daemon process = ChronicleApp" rather than a standalone daemon binary. No blocking dependency.

## Constraints

- **macOS 26 Tahoe only** (matches existing `platforms: [.macOS(.v26)]`)
- **Apple Silicon assumed** (ANE-backed models, CoreML)
- **SwiftUI MenuBarExtra** requires macOS 13+ (satisfied by macOS 26 floor)
- **TCC grants** must attach to the Xcode-built `.app` bundle (bundle ID `com.victor-software-house.chronicle`)
- **Single-instance enforcement** — only one ChronicleApp process at a time (future daemon host requirement)
- **Existing test suite** (108+ tests) must continue passing after library extraction
- **CLI `swift build && swift test`** must continue working for the CLI target
- **No cloud services** — all capture and ML remain on-device
- **CoreAudio taps for sysaudio** (ADR-0004) — no ScreenCaptureKit
