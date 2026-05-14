---
title: "Tahoe system-audio capture backend and sidecar crash-safety"
adr: ADR-0004
status: Proposed
date: 2026-05-13
prd: "PRD-001-resilient-multi-source-daemon"
decision: "Proposed: replace ScreenCaptureKit audio-only sysaudio with CoreAudio process taps; keep Opus CAF only as rotate-and-close segments until stronger crash-safety is proven"
---

# ADR-0004: Tahoe system-audio capture backend and sidecar crash-safety

## Status

Proposed

## Date

2026-05-13

## Requirement Source

- **PRD**: [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](../prd/PRD-001-resilient-multi-source-daemon.md)
- **Decision Point**: FR-1 (crash-resistant segmented audio capture), FR-3 (`chronicle sysaudio`), and the P11 requirement to flip the production audio default from WAV to Opus after parity and resilience are proven.

## Context

Chronicle targets macOS Tahoe 26+ only. No legacy macOS compatibility is required.

The current `sysaudio` implementation uses `ScreenCaptureKit.SCStream` with audio output only:

- `Sources/Chronicle/Core/Audio/SysAudioSource.swift`
- `Sources/Chronicle/Subcommands/SysAudio.swift`

P11 added Opus-in-CAF sidecar writing and a robustness layer in commit `78864ab`:

- `Sources/Chronicle/Core/Sinks/OpusCAFSink.swift`
- `Sources/Chronicle/Core/Audio/TCCPreflight.swift`
- `Sources/Chronicle/Core/Runtime/AsyncTimeout.swift`
- `scripts/make-app.sh`

Audit results changed the decision pressure:

1. `swift test` passes: 20/20 tests green on macOS 26.5 / Xcode 26.4.1 / Swift 6.3.1.
2. `scripts/make-app.sh` builds a codesign-bound `.app` bundle with `Info.plist entries=8`.
3. `swift build -c release -Xswiftc -warnings-as-errors` fails. Some diagnostics predate P11, but P11 added new warnings around `try await analyzer.cancelAndFinishNow()` wrappers.
4. `OpusCAFSink`'s crash-safety claim is false as currently implemented. A local repro wrote Opus packets to CAF with `AudioFileWritePackets` and exited without `AudioFileClose`; `ffprobe` rejected the file with `Missing packet table. It is required when block size or frame size are variable.` `afinfo` showed `audio packets: 0` and `not optimized`. The same file after `AudioFileClose` was valid.
5. `SysAudioSource` materialises audio with `CMBlockBufferGetDataPointer` and manual byte copies. Apple's ScreenCaptureKit sample uses `CMSampleBuffer.withAudioBufferList` and `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` instead.
6. Repo docs now contradict themselves: `AGENTS.md` contains new `.app` bundle TCC flow and older parent-app TCC guidance; `README.md` still references `OpusOggSink` in the future-phase list.

External evidence for Tahoe-era system-audio capture points away from ScreenCaptureKit for audio-only capture:

- Apple documents **Core Audio taps** for outgoing process/system audio. The flow is `CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device → IO proc, with `NSAudioCaptureUsageDescription` required in `Info.plist`; first recording from an aggregate device containing a tap prompts for System Audio Recording permission.
- `insidegui/AudioCap` is a dedicated Swift sample for macOS 14.4+ system audio capture using CoreAudio process taps and `NSAudioCaptureUsageDescription`.
- `makeusabrew/audiotee` captures system output with CoreAudio taps and writes raw PCM chunks; it documents terminal permission friction and references AudioCap for permission probing.
- `pHequals7/muesli` migrated in 2026 from ScreenCaptureKit to CoreAudio process taps for meeting system audio, citing removal of Screen Recording permission, hardware synchronization with mic input, and a cleaner System Audio Recording permission story.

## Decision Drivers

- **Tahoe-only correctness.** Use the best current macOS 26+ API surface, not compatibility-era code.
- **Functional proof over defensive folklore.** A pipeline that fails fast is not enough; it must capture valid audio and write valid sidecars under the target permission model.
- **Crash resilience.** PRD-001 allows ≤ 60 s worst-case audio loss after unclean termination; claims of ~20 ms loss require hard proof, not container assumptions.
- **Clean TCC model.** Permission prompts and System Settings entries must map to the app identity the operator can see and manage.
- **No private API by default.** AudioCap's private TCC SPI proves the permission gap, but chronicle should not depend on private TCC symbols for production.
- **Protocol architecture.** ADR-0001 already requires audio sources behind `AudioSource`; backend swap should not leak into subcommands.

## Considered Options

### Option 1: Keep ScreenCaptureKit for `sysaudio`, repair current implementation

Keep `SCStream` as the system-audio backend. Replace `CMBlockBufferGetDataPointer` with Apple's `withAudioBufferList` pattern, keep the `.app` bundle flow, keep TCC preflight and first-buffer watchdog, and fix docs/tests.

- Good, because least code churn from commit `78864ab`.
- Good, because ScreenCaptureKit remains Apple-official and can capture screen + audio together if future chronicle video context needs it.
- Good, because current `AudioSource` abstraction can stay mostly unchanged.
- Bad, because it keeps audio-only capture tied to Screen & System Audio Recording and ScreenCaptureKit's TCC quirks.
- Bad, because current failure already showed `CGPreflightScreenCaptureAccess()` can be `granted` while audio buffers are unusable.
- Bad, because `withTimeout` around `SCStream.startCapture()` cannot rescue a truly leaked continuation; the doc comment says so, but the code still presents it as defense-in-depth.
- Bad, because successful Tahoe audio-only implementations found during research prefer CoreAudio taps.

### Option 2: Replace `sysaudio` backend with CoreAudio process tap + aggregate device

Implement a Tahoe-only `CoreAudioSystemAudioSource` behind `AudioSource`:

1. Add `NSAudioCaptureUsageDescription` to `Info.plist`.
2. Create a private CoreAudio process tap using `CATapDescription`.
3. Create a private aggregate device containing that tap.
4. Start an IO proc / AUHAL callback on the aggregate device.
5. Convert tap buffers to `AVAudioPCMBuffer` using the tap's `kAudioTapPropertyFormat`.
6. Feed the existing `AnalyzerInput` and `PCMBufferRef` streams.
7. Destroy IO proc, aggregate device, and tap on stop/deinit.

- Good, because this is Apple's audio-specific API for outgoing process/system audio on current macOS.
- Good, because it uses `NSAudioCaptureUsageDescription` and System Audio Recording permission instead of piggy-backing on Screen Recording semantics.
- Good, because external Swift projects with the same problem use this path (`AudioCap`, `AudioTee`, `Muesli`).
- Good, because aggregate-device taps can align better with future mic+system synchronization than ScreenCaptureKit timestamps copied into timestampless PCM buffers.
- Good, because no legacy support is needed; macOS 26 target can assume this API exists.
- Bad, because CoreAudio tap setup is lower-level and more code than `SCStream`.
- Bad, because cleanup must be exact: stale private aggregate devices and taps must be destroyed on errors and deinit.
- Bad, because there is no public preflight API equivalent to `CGPreflightScreenCaptureAccess()` for system audio capture; first start triggers permission, and failure must be detected through public CoreAudio errors / no-buffer watchdog. Private TCC SPI remains out of scope.

### Option 3: Keep capture in a bundled app, move CLI to IPC client

Create a LaunchServices-owned app or helper that owns TCC and streams PCM to the CLI via Unix socket/XPC. The CLI becomes a client.

- Good, because TCC attribution becomes explicit and stable.
- Good, because future menu-bar onboarding could guide permissions cleanly.
- Good, because external Tahoe screen-capture projects report bundled app ownership as more reliable than plain executables.
- Bad, because much larger product shape change than P11 needs.
- Bad, because chronicle is currently a single Swift executable with thin subcommands; this introduces process supervision and IPC before core daemon features are done.
- Bad, because it does not by itself solve Opus CAF crash-safety.

### Option 4: Use private TCC SPI for audio permission check/request

Load `/System/Library/PrivateFrameworks/TCC.framework` and call `TCCAccessPreflight` / `TCCAccessRequest` for `kTCCServiceAudioCapture`, as AudioCap optionally does.

- Good, because it gives a direct system-audio permission probe not available publicly.
- Good, because it can improve onboarding UX in development builds.
- Bad, because it is private API and may break or violate distribution expectations.
- Bad, because chronicle does not need private API if it can surface first-start permission failures cleanly.
- Bad, because private permission checks would be a brittle foundation for a 24/7 daemon.

### Option 5: Revert P11 robustness and stay on WAV until later

Drop commit `78864ab`, keep pre-P11 WAV sidecars and ScreenCaptureKit as-is, and revisit later.

- Good, because it avoids building on questionable P11 code.
- Good, because it removes the false Opus CAF crash-safety claim until a clean storage design is ready.
- Bad, because it returns to known hangs and known WAV storage/corruption problems.
- Bad, because it delays the production storage goal without selecting a better architecture.

## Decision

Chosen option: **Option 2: Replace `sysaudio` backend with CoreAudio process tap + aggregate device**, with one storage correction from ADR-0002: **Opus CAF is valid only for rotate-and-close segments until unclosed/truncated CAF Opus readability is proven.**

This should be implemented as a proposed architecture change, then accepted after a live Tahoe 26+ smoke proves:

1. System Audio Recording prompt / grant works for `chronicle.app` with `NSAudioCaptureUsageDescription`.
2. `chronicle sysaudio` captures TTS playback through CoreAudio tap into non-zero PCM buffers.
3. SpeechAnalyzer emits finals from that PCM.
4. Opus CAF sidecar segments are closed and readable by `AVAudioFile`, `afinfo`, and `ffprobe`.
5. Killing the process mid-segment leaves all previous segments readable and loses no more than the current segment.

## Consequences

### Positive

- `sysaudio` moves to the current macOS audio-specific API instead of a screen-capture API used only for audio.
- TCC copy changes from Screen Recording folklore to explicit System Audio Recording usage text via `NSAudioCaptureUsageDescription`.
- The implementation aligns with current successful Swift references (`AudioCap`, `AudioTee`, `Muesli`) and Apple's CoreAudio tap sample.
- `SCStream` can remain available later for actual screen/video capture without carrying system-audio risk.
- The Opus default can still land, but only with a segment-close resilience model that matches observed CAF behavior.

### Negative

- CoreAudio tap implementation is lower-level and easier to leak resources. Mitigation: wrap tap, aggregate device, and IO proc in one `CoreAudioSystemAudioSource` owner with idempotent cleanup in every failure path.
- There is no public system-audio TCC preflight API. Mitigation: include `NSAudioCaptureUsageDescription`, rely on first-start prompt, and keep a first-valid-buffer watchdog with specific CoreAudio-tap error messages.
- Opus CAF no longer satisfies the previously claimed ~20 ms crash-loss story. Mitigation: rotate and close segments at PRD-accepted intervals (≤ 60 s), keep rolling raw PCM scratch for premium-lossless windows, and only claim ~20 ms loss if a later Ogg muxer or proven incremental packet-table strategy passes crash tests.
- Tests must become more realistic. Current Opus truncate test closes the file before truncating, so it does not simulate crash. Mitigation: add a subprocess crash test that writes packets and exits without `AudioFileClose`, then asserts expected behavior for the chosen container strategy.

### Neutral

- ADR-0002 needs amendment or a follow-up ADR note: "CAF is the Opus container, but resilience comes from rotation + close, not CAF packet-data append alone."
- `scripts/make-app.sh` remains useful because Tahoe TCC UI management works best with a bundled app identity.
- `TCCPreflight` should be narrowed or renamed: screen preflight remains relevant to future screen capture, not CoreAudio system-audio capture.

## Related

- **PRD**: [`PRD-001: Resilient multi-source chronicle daemon`](../prd/PRD-001-resilient-multi-source-daemon.md)
- **ADRs**:
  - [`ADR-0001: Modular pipeline architecture`](ADR-0001-modular-pipeline-architecture.md)
  - [`ADR-0002: Audio storage format`](ADR-0002-audio-storage-format.md) — requires amendment for CAF crash-safety semantics
- **Implementation files affected**:
  - `Info.plist`
  - `Sources/Chronicle/Core/Audio/SysAudioSource.swift`
  - `Sources/Chronicle/Core/Audio/TCCPreflight.swift`
  - `Sources/Chronicle/Core/Sinks/OpusCAFSink.swift`
  - `Sources/Chronicle/Subcommands/SysAudio.swift`
  - `Tests/ChronicleTests/Audio/`
  - `Tests/ChronicleTests/Sinks/`
  - `AGENTS.md`
  - `README.md`
  - `docs/STATUS.md`
- **External evidence**:
  - Apple Developer Documentation: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  - Apple Developer Documentation: [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos)
  - Apple Support: [Control access to screen and system audio recording on Mac](https://support.apple.com/en-afri/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/26/mac/26)
  - `insidegui/AudioCap`: [Sample code for recording system audio on macOS 14.4+](https://github.com/insidegui/AudioCap)
  - `makeusabrew/audiotee`: [CoreAudio tap CLI](https://github.com/makeusabrew/audiotee)
  - `pHequals7/muesli` commit `ada9493`: [Migrate system audio capture from ScreenCaptureKit to CoreAudio tap](https://github.com/pHequals7/muesli/commit/ada94936c0863e494305580cfceeaed8bd62fdeb)
