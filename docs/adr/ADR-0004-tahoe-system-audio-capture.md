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

## Implementation Recipe

This recipe converges the patterns used by `insidegui/AudioCap`, `BasedHardware/omi`, `pHequals7/muesli`, `yazinsai/OpenOats`, `sozercan/kaset`, `argmaxinc/argmax-sdk-swift-playground`, and `makeusabrew/audiotee`. Apple's own ["Capturing system audio with Core Audio taps"](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) sample is the upstream reference.

### Tap creation

```swift
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeSelfPIDs)
tapDesc.uuid = UUID()
tapDesc.muteBehavior = .unmuted
tapDesc.name = "chronicle-sysaudio-\(tapDesc.uuid.uuidString)"
var tapID: AudioObjectID = kAudioObjectUnknown
let st = AudioHardwareCreateProcessTap(tapDesc, &tapID)
```

Alternative initializer when only a single output device should be captured (Muesli, Kaset): build the tap against the default output device UID. Muesli's commit notes: "native call clients (Zoom, Teams) route audio through private pipelines that bypass the system's stereo mix; a device-level tap captures all audio flowing through the output device regardless of which app or pipeline produces it." Decision for chronicle: start with `stereoGlobalTapButExcludeProcesses:`; revisit device-level taps after live-mix coverage gaps are observed.

### Aggregate device

```swift
let aggUID = "com.victor-software-house.chronicle.sysaudio.\(UUID().uuidString)"
let outputUID = try AudioDeviceID.readDefaultSystemOutputUID()
let aggDesc: [String: Any] = [
  kAudioAggregateDeviceNameKey as String: "chronicle System Audio",
  kAudioAggregateDeviceUIDKey as String: aggUID,
  kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
  kAudioAggregateDeviceIsPrivateKey as String: true,
  kAudioAggregateDeviceIsStackedKey as String: false,
  kAudioAggregateDeviceTapAutoStartKey as String: true,
  kAudioAggregateDeviceSubDeviceListKey as String: [
    [kAudioSubDeviceUIDKey: outputUID]
  ],
  kAudioAggregateDeviceTapListKey as String: [
    [
      kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
      kAudioSubTapDriftCompensationKey: true,  // CFNumber non-zero per CoreAudio.h
    ]
  ],
]
var aggID: AudioObjectID = kAudioObjectUnknown
let st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
```

Key rules confirmed across all surveyed implementations:

- The tap list entries must be dictionaries with `kAudioSubTapUIDKey` string entries, never `CATapDescription` objects. Muesli's source comment: "passing objects crashes CoreAudio."
- `kAudioSubTapDriftCompensationKey` must be set per sub-tap. OMI's source comment: without it, the aggregate device's clock drifts relative to the real output device and "the system resamples on every IO cycle to compensate. That resampling produces periodic crackling/artifacts in *all* system audio playback (music, calls, etc.) even though we're only reading from the tap."
- Anchor with `kAudioAggregateDeviceMainSubDeviceKey` + `kAudioAggregateDeviceSubDeviceListKey` set to the real default output. AudioCap and OMI do this; bare tap-only aggregates work but anchoring keeps clock alignment correct.

### Stream format

```swift
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
var tapASBD = AudioStreamBasicDescription()
var addr = AudioObjectPropertyAddress(
  mSelector: kAudioTapPropertyFormat,
  mScope: kAudioObjectPropertyScopeGlobal,
  mElement: kAudioObjectPropertyElementMain
)
AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &tapASBD)
let sourceFormat = AVAudioFormat(streamDescription: &tapASBD)!
```

### IOProc and buffer materialization

```swift
let queue = DispatchQueue(label: "chronicle.sysaudio.ioproc", qos: .userInteractive)
var procID: AudioDeviceIOProcID?
let ioBlock: AudioDeviceIOBlock = { [weak self] _, inBuf, _, _, _ in
  guard let self,
        let pcm = AVAudioPCMBuffer(
          pcmFormat: sourceFormat,
          bufferListNoCopy: inBuf,
          deallocator: nil
        )
  else { return }
  self.handleTapBuffer(pcm)
}
let st1 = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue, ioBlock)
let st2 = AudioDeviceStart(aggID, procID)
```

`AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator:)` is the pattern used by AudioCap and argmax-sdk-swift-playground. Replaces the manual `CMBlockBufferGetDataPointer` + `memcpy` in the current `SysAudioSource.swift`.

### Teardown order (mandatory, top to bottom)

```
1. AudioDeviceStop(aggID, procID)
2. AudioDeviceDestroyIOProcID(aggID, procID)
3. AudioHardwareDestroyAggregateDevice(aggID)
4. AudioHardwareDestroyProcessTap(tapID)
```

This order is universal across AudioCap, OMI, Muesli, OpenOats, Kaset, argmax, audiotee. Reversing or skipping leaks audio objects that survive until reboot.

### Stale-aggregate cleanup at startup

```swift
// Enumerate kAudioHardwarePropertyDevices and destroy any aggregate whose UID
// begins with "com.victor-software-house.chronicle.sysaudio." — leftovers from
// prior crashes or kill -9. Muesli + Kaset both do this; otherwise Audio MIDI
// Setup accumulates orphan devices.
```

### Default-output-device change listener (production-grade)

Muesli installs an `AudioObjectPropertyListenerBlock` on `kAudioHardwarePropertyDefaultOutputDevice`. When the operator switches outputs (AirPods sleep/wake, Bluetooth swap, monitor unplug), the aggregate device's clock anchor goes stale and audio becomes silent or corrupted. The listener triggers full teardown + rebuild.

Chronicle should follow the same pattern for `chronicle sysaudio` because it is a 24/7 daemon. Mic source does not need it.

### IOProc-all-zero failure mode (open issue)

Apple Developer Forum [thread 825780](https://developer.apple.com/forums/thread/825780) (macOS 26.5 Beta, MacBook Air M2) documents a long-session failure mode where `AudioDeviceIOProc` keeps firing at expected cadence but every PCM sample is exactly `0.0f` while system audio is still audible. Heartbeat, timestamps, `kAudioDevicePropertyDeviceIsRunningSomewhere`, and `kAudioProcessPropertyIsRunningOutput` all read normal. Workaround: full teardown and rebuild of tap + aggregate device. Detection is hard because all-zero is indistinguishable from legitimate silence.

Chronicle mitigation strategy for FR-1 / FR-3:

- Run an RMS-on-rolling-window heartbeat as a `--verbose` diagnostic.
- If RMS has been zero for ≥ N minutes AND `kAudioProcessPropertyIsRunningOutput` reports active output on any non-self process, schedule a rebuild.
- Make the rebuild policy operator-configurable. False positives during quiet meetings are worse than silent dropouts in some workflows.

### Permission probing

There is no public TCC preflight API for `kTCCServiceAudioCapture`. Evidence:

- AudioCap (`AudioCap/ProcessTap/AudioRecordingPermission.swift`) uses **private TCC SPI** (`TCCAccessPreflight` and `TCCAccessRequest` from `/System/Library/PrivateFrameworks/TCC.framework`) behind a build flag.
- OMI source comment: "For Core Audio Taps, there's no explicit permission API. The system will prompt when we first try to create a tap."
- Kaset uses `CGPreflightScreenCaptureAccess()` as a proxy and notes that "When permission is missing the tap APIs return `noErr` but feed us only zeros while still installing the mute on WebKit" — so a first-buffer watchdog is still required.

Chronicle decision: rely on `NSAudioCaptureUsageDescription` + the system's first-use prompt + first-valid-buffer watchdog. No private TCC SPI in shipped builds. A `--verbose` diagnostic surface should report what permission state is observable from public API.

### CoreAudio HAL is synchronous IPC to coreaudiod

OMI source comment: "All CoreAudio HAL calls (CreateTap, CreateAggregateDevice, AudioDeviceStart) are synchronous IPC to coreaudiod via mach_msg. After wake from sleep the daemon can take seconds to respond, blocking the caller." Dispatch all setup/teardown calls to a dedicated `DispatchQueue`, not the main thread or actor isolation boundary.

## Storage Recipe (FR-1)

### Confirmed via local repro on macOS 26.5

- `OpusCAFSink` writes `kAudioFileCAFType` with `kAudioFormatOpus` packets via `AudioFileWritePackets`.
- Exit without `AudioFileClose` → `ffprobe` reports `Missing packet table. It is required when block size or frame size are variable`; `afinfo` reports `audio packets: 0`. File is unreadable.
- Exit after `AudioFileClose` → file is valid; `afinfo` reports `optimized`, correct packet count and duration.

`AudioFileWritePackets` does not flush the variable-bitrate packet table incrementally on Tahoe 26.5. The packet table is written at close time.

### Crash-safe Opus storage options

#### Option A: Segmented Opus CAF (rotate-and-close)

Keep `OpusCAFSink` and add rotation. Cut a new `.caf` segment every N seconds (PRD default 60 s; smaller for stricter resilience). Close the previous segment before starting the next. Crash loses only the current open segment. Concatenation at read time via `ffmpeg -f concat`.

- Good, because zero new dependencies.
- Good, because Apple-native; reads in every macOS tool.
- Good, because matches FR-1 acceptance Gherkin closely.
- Bad, because every rotation closes a file and opens a new one — non-zero CPU and IO.
- Bad, because crash loss can be up to one full segment rather than ~20 ms.

#### Option B: Ogg-Opus muxer over AVAudioConverter Opus packets

Use the existing AVAudioConverter Opus pipeline to emit packets. Wrap packets manually in Ogg pages (Ogg framing per [IETF RFC 7845 / draft-ietf-codec-oggopus](https://datatracker.ietf.org/doc/draft-ietf-codec-oggopus/10/)). Flush page after every K packets (~20 ms × K). Each page is self-describing and CRC32-checked. Mid-stream truncation drops only the in-flight page.

- Good, because matches the original ADR-0002 "~20 ms loss" claim.
- Good, because `.opus` files are the universal external interchange format.
- Good, because still uses Apple's Opus encoder; no libopus dep.
- Good, because reference implementations exist: `element-hq/swift-ogg` and `symblai/opus-encdec` document the page layout; the muxer side is roughly 80-120 LOC.
- Bad, because we own the muxer correctness bug surface (lacing values, page sequence numbers, granule position).
- Bad, because tests must include third-party-decoder validation (`ffprobe`, `opusinfo`).

#### Option C: libopusenc XCFramework (`sbooth/opus-binary-xcframework`)

Vendor Opus + Opusfile + libopusenc as an SPM binary target. Use libopusenc, which natively writes Ogg-Opus with proper framing.

- Good, because Ogg framing is fully owned by upstream Xiph code.
- Good, because the upstream library is heavily used and audited.
- Bad, because adds a non-Apple dependency.
- Bad, because requires the matching Ogg XCFramework dependency.
- Neutral, because the XCFramework binary target keeps build complexity reasonable.

### Recommendation

Ghost-deploy Option A (segmented CAF) first because it is the fastest path to a correctness-aligned default. Track Option B as the follow-up when chronicle's resilience guarantees need to drop from segment-loss to packet-loss, and when external `.opus` interop is desired by an operator workflow. Treat Option C as the escape hatch if Option B muxer correctness becomes a maintenance burden.

ADR-0002 amendment scope: "Opus is encoded via Apple AudioToolbox; default container is CAF in segmented rotate-and-close mode. `.opus` (Ogg) export is via on-demand `ffmpeg -i in.caf -c:a copy out.opus` at consumer time; in-process Ogg muxing remains a future option (Option B above)."

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
  - Apple Developer Forum [thread 825780](https://developer.apple.com/forums/thread/825780) — IOProc all-zero failure on Tahoe 26.5
  - `insidegui/AudioCap` — [ProcessTap.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/ProcessTap.swift), [AudioRecordingPermission.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/AudioRecordingPermission.swift) (private TCC SPI behind build flag)
  - `BasedHardware/omi` — [SystemAudioCaptureService.swift](https://github.com/BasedHardware/omi/blob/main/desktop/Desktop/Sources/SystemAudioCaptureService.swift)
  - `pHequals7/muesli` — [CoreAudioSystemRecorder.swift](https://github.com/pHequals7/muesli/blob/main/native/MuesliNative/Sources/MuesliNativeApp/CoreAudioSystemRecorder.swift), migration commit [ada9493](https://github.com/pHequals7/muesli/commit/ada94936c0863e494305580cfceeaed8bd62fdeb)
  - `yazinsai/OpenOats` — [SystemAudioCapture.swift](https://github.com/yazinsai/OpenOats/blob/main/OpenOats/Sources/OpenOats/Audio/SystemAudioCapture.swift)
  - `sozercan/kaset` — [ProcessTapHelper.swift](https://github.com/sozercan/kaset/blob/main/Sources/Kaset/Services/Audio/ProcessTapHelper.swift)
  - `argmaxinc/argmax-sdk-swift-playground` — [ProcessTapper.swift](https://github.com/argmaxinc/argmax-sdk-swift-playground/blob/main/Playground/Audio/ProcessTapper.swift) (WhisperKit integration)
  - `makeusabrew/audiotee` — [AudioTapManager.swift](https://github.com/makeusabrew/audiotee/blob/main/Sources/AudioTeeCore/Core/AudioTapManager.swift)
  - `atelier-socle/swift-capture-kit` — [PCM ring buffer fix](https://github.com/atelier-socle/swift-capture-kit/commit/15a9d1009ab8f4e1022ec9a36d4abb6f0df08882) (AAC-LC frame alignment)
  - `pablo-health/AudioCaptureKit` — [Repository](https://github.com/pablo-health/AudioCaptureKit)
  - `alta/swift-opus` — [Type-safe Opus packet bindings](https://github.com/alta/swift-opus)
  - `sbooth/opus-binary-xcframework` — [Opus + Opusfile + libopusenc SPM binary](https://github.com/sbooth/opus-binary-xcframework)
  - `element-hq/swift-ogg` — [opus/ogg ↔ m4a converter](https://github.com/element-hq/swift-ogg)
  - IETF [draft-ietf-codec-oggopus-10](https://datatracker.ietf.org/doc/draft-ietf-codec-oggopus/10/) — Ogg-Opus framing spec
  - Apple [CAF File Specification](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_overview/CAF_overview.html) — Packet Table chunk + Free chunk semantics
