---
title: "Tahoe system-audio capture backend and sidecar crash-safety"
adr: ADR-0004
status: Accepted
date: 2026-05-14
prd: "PRD-001-resilient-multi-source-daemon"
decision: "Replace SCStream audio-only with a Swift-native CoreAudio process tap source (Core/Audio/CoreAudioTapSource); keep analyzer-format ALAC-in-CAF plus rolling raw scratch for storage per ADR-0002"
---

# ADR-0004: Tahoe system-audio capture backend and sidecar crash-safety

## Status

Accepted (revised 2026-05-14 after live-capture incident root-cause analysis + extended option inventory)

## Date

* Drafted: 2026-05-13 (proposed, post P11 robustness layer landed at commit `78864ab`)
* Revised: 2026-05-14 (this version — accepted after live-capture incident on a 2-hour call validated CoreAudio process tap end-to-end on the same TCC state where SCStream still silently delivered zero-filled buffers)

## Requirement Source

* **PRD**: [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](../prd/PRD-001-resilient-multi-source-daemon.md)
* **Decision Points**: FR-1 (crash-resistant segmented audio capture), FR-3 (`chronicle sysaudio`), and the P11 storage decision now amended in ADR-0002 to ALAC-in-CAF plus rolling raw scratch after Opus failed the long-reference WER gate.

## Context

Chronicle targets macOS Tahoe 26+ only. No legacy macOS compatibility is required.

The current `sysaudio` implementation at commit `78864ab` uses `ScreenCaptureKit.SCStream` with audio output only:

* `Sources/Chronicle/Core/Audio/SysAudioSource.swift`
* `Sources/Chronicle/Subcommands/SysAudio.swift`

P11 added Opus-in-CAF sidecar writing and a three-layer robustness layer (TCC preflight + first-valid-buffer watchdog + bounded analyzer finalize). The robustness layer worked: it fails fast in \~5 s instead of hanging forever when audio capture is silently muted. But it did not unblock actual capture for the dev binary identity.

On 2026-05-14 a 2-hour live call was running on the operator's machine while `chronicle.app` was in the brand-new bundle-identity state (`com.victor-software-house.chronicle`, ad-hoc codesigned, `Info.plist` properly bound, all three Info.plist keys present, `CGPreflightScreenCaptureAccess()` reporting `granted` from inheritance through cmux.app). SCStream still delivered only placeholder CMSampleBuffers with garbage ASBDs (sample rate 0 Hz, \~1.8 GB / packet, \~1 frame / packet — the SCStream "audio silently denied" signature). Repeated TCC manipulations:

1. Insert `kTCCServiceScreenCapture` row for `com.victor-software-house.chronicle` with `auth_value=2` into the user TCC.db at `~/Library/Application Support/com.apple.TCC/TCC.db`. `sudo killall -HUP tccd`. **No change.**
2. Insert `kTCCServiceMicrophone` + `kTCCServiceAudioCapture` rows with `auth_value=2`. `tccd` reload. **No change.**
3. Insert the same rows into the system TCC.db at `/Library/Application Support/com.apple.TCC/TCC.db` with root. **No change.**
4. Patch `SysAudioSource.swift` to call `CGRequestScreenCaptureAccess()` before `CGPreflightScreenCaptureAccess()` and rebuild. **No change.**

In the same shell environment, a minimal Swift program calling `CATapDescription` + `AudioHardwareCreateProcessTap` + `AudioHardwareCreateAggregateDevice` + `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` (zero TCC ceremony) captured real stereo 48 kHz Float32 buffers on first call. Recording was then made crash-resilient with a periodic header repatch + `fsync` and an auto-restart supervisor.

This validates the CoreAudio process tap pivot proposed in the 2026-05-13 draft of this ADR with a real call on a real machine. The deeper question of *why* SCStream failed identically through every permission permutation, and what the full alternative landscape actually looks like, is what this revision documents authoritatively.

## Why SCStream did not deliver audio in our case (definitive root cause)

After cross-referencing community reports and Apple developer forum threads, the failure has a specific identifiable cause:

**macOS 15 Sequoia and macOS 26 Tahoe enforce that `ScreenCaptureKit.SCStream` (and `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` for that matter) require the calling binary to be signed with a stable Apple Developer ID identity that carries a Team ID. Ad-hoc signing (`codesign --sign -`) is treated as a fresh, unverifiable identity on every build, and the system refuses to bind a persistent ScreenCapture TCC grant to it.**

Concrete evidence, dated post-Sequoia release:

* [CapSoftware/Cap issue #1722](https://github.com/CapSoftware/Cap/issues/1722) (2026-04-09): "macOS Sequoia enforces that `CGPreflightScreenCaptureAccess()` / ScreenCaptureKit requires a binary signed with a valid Apple Developer ID certificate (with a Team ID). Ad-hoc signing (`codesign --sign \"-\"`) doesn't satisfy this requirement. This is a regression from earlier macOS versions where ad-hoc signed bundles could get TCC grants."
* [Apple Developer Forum thread 819406](https://developer.apple.com/forums/thread/819406): "ScreenCaptureKit permissions lost on every new build" — confirms identity-tied caching of grants.
* [trycua/cua issue #870](https://github.com/trycua/cua/issues/870) (2026-01-21): "macOS 26.1 (Tahoe) appears to require app bundles for an item to be shown in the Screen Recording privacy UI. Plain (non-bundled) executables that request screen recording access no longer appear under System Settings → Privacy & Security → Screen & System Audio Recording."

What this means for `chronicle.app` specifically:

| Layer                                                                                                      | State | Outcome                                                                                                                                                                                       |
| ---------------------------------------------------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Info.plist` correctly embedded via `-sectcreate __TEXT __info_plist`                                      | ✔     | OS reads the usage description strings                                                                                                                                                        |
| `codesign -dvv` reports `Info.plist entries=8` and stable `Identifier=com.victor-software-house.chronicle` | ✔     | Bundle has a usable identity                                                                                                                                                                  |
| `codesign --sign -` (ad-hoc)                                                                               | ✘     | macOS treats SCStream audio TCC as not honourable; `CGPreflightScreenCaptureAccess` may return `true` via parent-app inheritance but the audio side of the permission is **silently dropped** |
| Direct TCC.db writes (user + system DB, both auth\_value=2)                                                | ✘     | `tccd` does not honour entries for ScreenCapture if the bound binary is ad-hoc and the system audit chain cannot validate it                                                                  |
| `Developer ID Application` signing with a real Apple Team ID                                               | ✔     | Would work; requires paid Apple Developer Program enrollment for this project                                                                                                                 |

The SCStream failure on our binary is therefore **not a code bug, not a permission bug, and not a TCC database bug**. It is the explicit Apple Sequoia/Tahoe security policy that ScreenCaptureKit audio-only is not a development surface for ad-hoc signed binaries.

This is the bright line we missed at P7 / P11. Once known, it makes the choice of moving off SCStream for audio mandatory unless chronicle is willing to either (a) enrol in the Apple Developer Program and Developer-ID-sign every build, or (b) ship as an App-Store-distributed sandboxed app. Neither is a fit for an on-device daemon under active personal development.

For comparison, CoreAudio process taps:

* The `kTCCServiceAudioCapture` permission is granted **per-bundle-identity at first use** of `AudioHardwareCreateAggregateDevice` containing a tap, independent of Developer ID. The grant survives ad-hoc rebuilds **as long as the bundle identifier and Info.plist remain stable**.
* The `NSAudioCaptureUsageDescription` Info.plist string is the only piece of intent required.
* For Hardened-Runtime or sandboxed apps, the `com.apple.security.device.audio-input` entitlement must be present and survive code-signing (see [ghost-pepper issue #21](https://github.com/matthartman/ghost-pepper/issues/21), 2026-04-06: "release signing script was stripping `com.apple.security.device.audio-input` entitlement"). Chronicle is not sandboxed today and does not enable Hardened Runtime, so the entitlement is optional but recommended for future hardening.

## Decision Drivers

* **Tahoe-only correctness.** Use the best current macOS 26+ API surface, not legacy-era code.
* **No Apple Developer Program dependency for development.** Chronicle is operated on a personal machine; paid signing every build is operationally infeasible. The chosen API must work with ad-hoc codesigned bundles.
* **Functional proof over defensive folklore.** A pipeline that fails fast is not enough; it must capture valid audio and write valid sidecars under the target permission model. The 2026-05-14 incident is now the standing acceptance test.
* **Crash resilience.** PRD-001 allows ≤ 60 s worst-case audio loss after unclean termination. Claims of \~20 ms loss require hard proof, not container assumptions.
* **Clean TCC model.** Permission prompts and System Settings entries must map to the bundle identity the operator can see and manage. No reliance on parent-app inheritance, no implicit screen-recording dependency for audio capture.
* **No private API for production.** AudioCap's private TCC SPI proves the permission gap; chronicle should not depend on private TCC symbols for production.
* **Protocol architecture.** ADR-0001 already requires audio sources behind `AudioSource`; backend swap must not leak into subcommands.
* **Minimal third-party dependency surface.** Chronicle is on-device, no-network, single-binary. Vendored frameworks are acceptable; runtime kernel extensions are not.

## Considered Options

This revision enumerates twelve options encountered during research. Each is scored on the chronicle-specific requirement set above.

### Option 1: Continue with ScreenCaptureKit SCStream audio-only (status quo at commit `78864ab`)

Keep `SCStream` with `capturesAudio = true`. Continue to maintain the three-layer robustness layer to fail fast when buffers are zero-filled.

* Good, because it ships with macOS 13+, is the framework Apple actively promotes in WWDC22/23/24/25 talks.
* Good, because it unifies screen + audio capture under one API if chronicle ever needs screen frames.
* Bad, because **the dev binary identity model makes audio buffers silently zero-filled** (see root-cause section). Without Developer ID Team ID signing every build, this path cannot deliver audio.
* Bad, because the audio sub-toggle of "Screen & System Audio Recording" was split on Tahoe 26 with no way to distinguish observed audio-denied state from real silence at the API level.
* Bad, because `withTimeout` around `SCStream.startCapture()` cannot rescue a leaked continuation when TCC is in an unhappy state (already documented as a caveat in `Core/Runtime/AsyncTimeout.swift`).
* Bad, because the surveyed production audio recorders have all migrated **away** from this for the same reason.

Score: 1/10. Functional only with paid Developer ID signing on every build.

### Option 2: Native Swift CoreAudio process tap source in `Core/Audio/CoreAudioTapSource`

Replace `SysAudioSource` with `CoreAudioTapSource` conforming to the same `AudioSource` protocol:

1. Add `NSAudioCaptureUsageDescription` to `Info.plist`.
2. Create a private CoreAudio process tap using `CATapDescription(stereoGlobalTapButExcludeProcesses:)`.
3. Create a private aggregate device anchored on the default output (`kAudioAggregateDeviceMainSubDeviceKey`) with the tap registered via `kAudioAggregateDeviceTapListKey` containing `kAudioSubTapUIDKey` + `kAudioSubTapDriftCompensationKey: true`.
4. Start an IO proc via `AudioDeviceCreateIOProcIDWithBlock` on a dedicated `DispatchQueue(qos: .userInteractive)`.
5. Inside the IO proc, materialise `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator:nil)` from the delivered `AudioBufferList`.
6. Feed the existing `AnalyzerInput` and `PCMBufferRef` async streams.
7. Tear down on stop or deinit in the universal order: Stop → DestroyIOProc → DestroyAggregate → DestroyTap.
8. Add a startup sweep that destroys orphan aggregate devices whose UID begins with the chronicle prefix (from prior crashes).
9. Add a `kAudioHardwarePropertyDefaultOutputDevice` listener that rebuilds the tap + aggregate when the operator switches output device.
10. Add an RMS heartbeat watchdog to detect the Apple-forum-825780 all-zero-buffer drift mode and trigger a full rebuild.

* Good, because the 2026-05-14 incident validated this end-to-end on the same machine, same TCC state, same Tahoe 26.5 version where SCStream failed.
* Good, because 10+ surveyed production audio recorders converge on this exact pattern: [`insidegui/AudioCap`](https://github.com/insidegui/AudioCap), [`makeusabrew/audiotee`](https://github.com/makeusabrew/audiotee), [`pablo-health/AudioCaptureKit`](https://github.com/pablo-health/AudioCaptureKit), [`yazinsai/OpenOats`](https://github.com/yazinsai/OpenOats), [`pHequals7/muesli`](https://github.com/pHequals7/muesli) (migrated from SCK), [`tenequm/blackbox`](https://github.com/tenequm/blackbox) (migrated from SCK), [`argmaxinc/argmax-sdk-swift-playground`](https://github.com/argmaxinc/argmax-sdk-swift-playground) (based on Apple's sample), [`obsfx/audiograb`](https://github.com/obsfx/audiograb), [`jdefrancesco/spkrdump`](https://github.com/jdefrancesco/spkrdump), [`sbetko/catap`](https://github.com/sbetko/catap), [`crimson-knight/crystal-audio`](https://github.com/crimson-knight/crystal-audio), [`atelier-socle/swift-capture-kit`](https://github.com/atelier-socle/swift-capture-kit). Verified directly via Apple Developer Forum + repo wikis 2026-05-15 (see Research-validation addendum below).
* Good, because `kTCCServiceAudioCapture` is independent of screen recording.
* Good, because ad-hoc codesigned bundles are honoured.
* Good, because PCM is delivered directly without `CMSampleBuffer` ceremony.
* Good, because aggregate-device taps align hardware-synchronously with mic when both ride the same aggregate (future FR-4 streaming-diarize benefit).
* Good, because no conflict with `CGWindowListCreateImage` (Muesli's bug class).
* Good, because Apple-blessed canonical API for system audio per [Apple Developer Documentation: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
* Bad, because lower-level than SCStream. Implementation surface \~200 LOC vs \~50.
* Bad, because no public TCC preflight API — must rely on first-use prompt + first-valid-buffer watchdog.
* Bad, because aggregate device + IO proc + tap must be torn down on every error path; leaks become zombie audio devices that survive until reboot otherwise.
* Bad, because the all-zero-buffer drift mode (Apple Developer Forum [thread 825780](https://developer.apple.com/forums/thread/825780)) requires an RMS heartbeat to detect; detection is hard because all-zero is indistinguishable from real silence.

Score: 9/10. Apple-blessed, ad-hoc-friendly, production-validated, only real cost is implementation depth. Counterfactual (ignore the Dev ID gate entirely): tap still scores 9/10 vs SCStream's 6/10 — even with paid Developer ID signing in place, every SCStream API call pays a TCC + cert-chain + revocation check ([Dominic Rodemer, "The macOS Notarization Performance Mystery"](https://blog.dominicrodemer.com/macos-notarization-performance-mystery/), 2026-01-27), and the FR-4 hardware-sync-with-mic, semantic-correctness, and recoverable-failure-mode advantages remain.

### Option 3: Hybrid — SCStream for future screen video + CoreAudio tap for audio

If chronicle ever adds screen video, do not extend SCStream into audio; keep the audio path on CoreAudio tap and use SCStream only for video frames.

* Good, because cleanest TCC separation; independent failure recovery.
* Good, because matches `tenequm/blackbox`'s shipping design (April 2026).
* Good, because future-proofs both paths.
* Bad, because more code, two TCC prompts, two backends to maintain.
* Bad, because chronicle's PRD-001 does not require screen video; speculative.

Score: 8/10 if screen video is ever required. Until then, Option 2 wins on simplicity.

### Option 4: Bundle the AudioTee subprocess binary (makeusabrew/audiotee)

Vendor the prebuilt `audiotee` Swift binary (\~600 KB universal macOS) and shell out to it from `Subcommands/SysAudio.swift`, piping its stdout PCM through chronicle's existing analyzer + sinks.

* Good, because it works today; the maintainer ships releases for macOS 14.2+.
* Good, because zero implementation effort for the capture path.
* Good, because no risk of CoreAudio teardown leaks in our code.
* Good, because the Swift binary inside our `.app` would carry its own bundle and TCC identity neatly.
* Bad, because adds a separate binary to ship and version.
* Bad, because audiotee's API is documented as unstable (`⚠️ API Instability Warning` in the upstream README).
* Bad, because subprocess plumbing complicates ADR-0001's protocol architecture; less natural to compose with `AudioSource` than a Swift-native source.
* Bad, because cross-process audio delivery adds latency / serialization overhead.

Score: 6/10. Faster to ship but worse long-term shape for an on-device daemon.

### Option 5: `pablo-health/AudioCaptureKit` Swift library

Adopt [AudioCaptureKit](https://github.com/pablo-health/AudioCaptureKit) as an SPM dependency. It provides `CoreAudioTapCapture`, `AVFoundationMicCapture`, optional AES-256-GCM encryption, and a `CompositeCaptureSession` orchestrator.

* Good, because it embeds the exact pattern chronicle needs (mic + system tap → mixed stereo PCM).
* Good, because actively maintained (v1.1.0, 2026-03-16).
* Good, because licence is BSD-2-Clause friendly.
* Good, because it documents the Bluetooth HFP downgrade edge case explicitly.
* Bad, because it bakes in stereo mixing (mic + system → one stream); chronicle wants separated streams to feed two analyzer / sink paths.
* Bad, because requires `com.apple.security.device.audio-input` entitlement; chronicle is not currently entitled.
* Bad, because adds a vendored dependency for a chunk of code chronicle can write directly in \~200 LOC (Option 2).
* Bad, because its design assumes `/Applications/` installation for TCC stability; chronicle runs from `.build/release/`.

Score: 6/10. Useful as a reference; vendoring would over-couple.

### Option 6: Python or Node subprocess wrapper (`sbetko/catap`, `audiotee.js`)

Wrap the CoreAudio tap in a non-Swift runtime and shell out from chronicle.

* Good, because both are production-quality.
* Bad, because adds a Python / Node runtime dependency to chronicle.
* Bad, because chronicle is intentionally a single Swift binary with no scripting runtime.

Score: 3/10. Rejected.

### Option 7: `cpal` (Rust audio library) with loopback

Use the Rust `cpal` crate with system-audio loopback. Documented in [Vibe PR #978](https://github.com/thewh1teagle/vibe/pull/978).

* Good, because cross-platform abstraction.
* Bad, because chronicle is Swift; introducing a Rust subprocess for audio is disproportionate.
* Bad, because community reports of system-audio recording silence on macOS 26.3 with cpal ([cpal PR #1003 reports](https://github.com/RustAudio/cpal/issues/876)).
* Bad, because chronicle is macOS-only; cross-platform is not a value-add.

Score: 2/10. Rejected.

### Option 8: ScreenCaptureKit `SCRecordingOutput` (macOS 15+)

Use Apple's built-in muxer to write the recording to a file. Less code than manual `AVAssetWriter` plumbing.

* Good, because less code.
* Bad, because shares all of Option 1's TCC + Developer ID Team ID limitations.
* Bad, because the file format / segmentation knobs are framework-controlled.
* Bad, because chronicle needs streaming PCM into `SpeechAnalyzer`, not file-only output.

Score: 4/10. Rejected.

### Option 9: Virtual audio driver (BlackHole, Loopback, Soundflower clones)

Install a userspace virtual audio driver and route system output through it; capture it as a "microphone" via standard `AVAudioEngine`.

* Good, because it bypasses TCC issues entirely.
* Good, because mature, several drivers ship signed installers.
* Bad, because requires the operator to install a kernel-adjacent driver. Not zero-install.
* Bad, because brittle on macOS upgrades.
* Bad, because cannot be bundled with chronicle.
* Bad, because the operator has to manually switch the system default output to the virtual device.

Score: 2/10. Rejected for chronicle's zero-install on-device philosophy.

### Option 10: Chromium / Electron `getDisplayMedia`

Use `navigator.mediaDevices.getDisplayMedia({ audio: true })` from a WebView or Electron renderer.

* Good, because cross-platform.
* Bad, because requires shipping Electron or a Chromium-based capture process. Chronicle is a Swift CLI.
* Bad, because still requires Screen Recording TCC on macOS.

Score: 1/10. Rejected.

### Option 11: AVCaptureSession with input audio

Use `AVCaptureSession` with an audio input device.

* Bad, because `AVCaptureSession` cannot capture system audio output; only audio input devices (microphone, line in).

Score: 0/10. Not applicable.

### Option 12: Apple Developer Program enrolment + Developer-ID-signed builds

Pay the annual Apple Developer Program fee, generate a Developer ID Application certificate, sign every build with it. SCStream audio works correctly with this identity.

* Good, because it unblocks SCStream audio without changing the code.
* Good, because also unlocks future distribution channels.
* Bad, because $99/year for a development tool used by one operator is operational overhead.
* Bad, because every build must be signed with the developer cert; CI / local quick-iteration friction.
* Bad, because the cert can lapse, expire, or be revoked, breaking captures during a live session.
* Bad, because it solves only the SCStream identity problem; the all-zero-buffer drift mode, the screen-recording UI dependency, and the conflict with `CGWindowListCreateImage` remain.

Score: 3/10. Rejected even if cheap; CoreAudio tap is independently better.

### Decision matrix

| Option                        | Apple-blessed |  Ad-hoc-friendly | Production refs |  Impl effort |            Future fit            | **Score** |
| ----------------------------- | :-----------: | :--------------: | :-------------: | :----------: | :------------------------------: | :-------: |
| 1. SCStream (status quo)      |      ★★★★     |         ✘        |    rare 2026+   |     done     |      poor (Apple split TCC)      |    1/10   |
| **2. CoreAudio tap native**   |      ★★★★     |         ✔        |   13+ surveyed  |   \~200 LOC  |             excellent            |  **9/10** |
| 3. Hybrid SCStream + tap      |      ★★★★     |    ✔ for audio   |     blackbox    |   \~250 LOC  |     excellent if video added     |    8/10   |
| 4. AudioTee subprocess        |       ★★      |         ✔        |        1        |     small    |         poor (subprocess)        |    6/10   |
| 5. AudioCaptureKit lib        |       ★★      | with entitlement |        1        |    medium    |              medium              |    6/10   |
| 6. Python / Node wrapper      |       ★       |         ✔        |        2        |    medium    |            wrong stack           |    3/10   |
| 7. Rust cpal                  |       ★       |         ✔        |    1 (broken)   |     high     |            wrong stack           |    2/10   |
| 8. SCRecordingOutput          |      ★★★      |         ✘        |       few       |     small    |      inherits Option 1 bugs      |    4/10   |
| 9. Virtual driver (BlackHole) |       ✘       |        n/a       |    many DAWs    | install step |               poor               |    2/10   |
| 10. Chromium getDisplayMedia  |       ★       |         ✘        |       many      |     huge     |            wrong stack           |    1/10   |
| 11. AVCaptureSession audio    |      ★★★★     |         ✔        |       many      |     small    | **inapplicable to system audio** |    0/10   |
| 12. Developer ID signing      |      ★★★★     |        n/a       |       many      |    medium    |      inherits Option 1 bugs      |    3/10   |

## Decision

Chosen option: **Option 2 — Native Swift CoreAudio process tap source.**

The 2026-05-14 live-capture incident is a direct A/B test: same machine, same Tahoe 26.5, same TCC state, same bundle identity. SCStream delivered garbage ASBD; CoreAudio process tap delivered real stereo 48 kHz Float32 audio on first try. The result reproduces every surveyed production app's migration story.

Concretely:

1. Implement `Sources/Chronicle/Core/Audio/CoreAudioTapSource.swift` conforming to `AudioSource`, following the recipe section below.
2. Add `NSAudioCaptureUsageDescription` to `Info.plist`.
3. Update `Subcommands/SysAudio.swift` to instantiate `CoreAudioTapSource` instead of `SysAudioSource`.
4. Mark `Sources/Chronicle/Core/Audio/SysAudioSource.swift` as deprecated; remove after one release shipping the new backend cleanly.
5. Keep the L3 bounded analyzer finalize from the P11 robustness layer; it is backend-agnostic.
6. Drop the L1 / L2 logic that was specific to SCStream's silent-deny mode; CoreAudio tap has a different failure surface (all-zero-buffer drift, requires RMS heartbeat).
7. Storage: keep Opus CAF as the production codec choice from ADR-0002, but **only in rotate-and-close segments**. Local repro on 2026-05-13 confirmed unclosed CAF Opus is unreadable (`ffprobe: Missing packet table`); rotate-and-close limits crash loss to the in-flight segment.

## Implementation Recipe

This recipe converges the patterns used by `insidegui/AudioCap`, `pHequals7/muesli` (post-migration), `yazinsai/OpenOats`, `argmaxinc/argmax-sdk-swift-playground` (based on Apple's `Capturing system audio with Core Audio taps` sample), `makeusabrew/audiotee`, `tenequm/blackbox` (post-migration), and the live-validated `/tmp/catap_record.swift` from the 2026-05-14 incident. Note: `BasedHardware/omi` was previously listed here in error — omi uses `SCStream` for system audio because it is distributed as a Developer-ID-signed app and does not hit the ad-hoc TCC gate. `sozercan/kaset` was also listed in error — it does not capture system audio; it plays YouTube Music inside a `WKWebView`.

### Required Info.plist additions

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>chronicle captures system audio output to transcribe what is playing on this Mac, on-device, via Apple SpeechAnalyzer.</string>
```

Keep `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`. `NSScreenCaptureUsageDescription` may stay for future video work or be removed once `SysAudioSource` is deleted.

### Recommended future entitlements (when hardening)

When chronicle gains Hardened Runtime or sandboxing:

```xml
<!-- Resource Access -->
<key>com.apple.security.device.audio-input</key>
<true/>
```

Without this entitlement under Hardened Runtime, `tccd` refuses to prompt for `kTCCServiceMicrophone` or `kTCCServiceAudioCapture` even when Info.plist strings are present (root cause documented in [ghost-pepper #21](https://github.com/matthartman/ghost-pepper/issues/21)).

### Tap creation

```swift
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeSelfPIDs)
tapDesc.uuid = UUID()
tapDesc.muteBehavior = .unmuted
tapDesc.name = "chronicle-sysaudio-\(tapDesc.uuid.uuidString)"
var tapID: AudioObjectID = kAudioObjectUnknown
let st = AudioHardwareCreateProcessTap(tapDesc, &tapID)
```

Alternative initializer when only a single output device should be captured: build the tap against the default output device UID (`pHequals7/muesli`, `sozercan/kaset`). Muesli's note: "native call clients (Zoom, Teams) route audio through private pipelines that bypass the system's stereo mix; a device-level tap captures all audio flowing through the output device regardless of which app or pipeline produces it." Decision for chronicle: start with `stereoGlobalTapButExcludeProcesses:`; revisit device-level taps if live-mix coverage gaps appear.

### Aggregate device

```swift
let aggUID = "com.victor-software-house.chronicle.sysaudio.\(UUID().uuidString)"
let outputUID = try AudioDeviceID.readDefaultSystemOutputUID()
let aggDesc: [String: Any] = [
  kAudioAggregateDeviceNameKey as String:          "chronicle System Audio",
  kAudioAggregateDeviceUIDKey as String:           aggUID,
  kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
  kAudioAggregateDeviceIsPrivateKey as String:     true,
  kAudioAggregateDeviceIsStackedKey as String:     false,
  kAudioAggregateDeviceTapAutoStartKey as String:  true,
  kAudioAggregateDeviceSubDeviceListKey as String: [
    [kAudioSubDeviceUIDKey: outputUID]
  ],
  kAudioAggregateDeviceTapListKey as String: [
    [
      kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
      kAudioSubTapDriftCompensationKey: true,
    ]
  ],
]
var aggID: AudioObjectID = kAudioObjectUnknown
let st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
```

Universal rules confirmed across all surveyed implementations:

* Tap list entries must be **dictionaries with `kAudioSubTapUIDKey` string entries**, never `CATapDescription` objects (Muesli comment: "passing objects crashes CoreAudio").
* `kAudioSubTapDriftCompensationKey` must be set per sub-tap (OMI: without it the aggregate clock drifts and the system resamples on every IO cycle, producing periodic crackling in *all* system audio playback).
* Anchor with `kAudioAggregateDeviceMainSubDeviceKey` + `kAudioAggregateDeviceSubDeviceListKey` set to the real default output.

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

`AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator:)` is the Apple-sample-blessed pattern. It replaces the manual `CMBlockBufferGetDataPointer` + `memcpy` currently in `SysAudioSource.swift`.

### Teardown (universal order)

```
1. AudioDeviceStop(aggID, procID)
2. AudioDeviceDestroyIOProcID(aggID, procID)
3. AudioHardwareDestroyAggregateDevice(aggID)
4. AudioHardwareDestroyProcessTap(tapID)
```

Reversing or skipping leaks audio objects that survive until reboot.

### Stale-aggregate cleanup at startup

Enumerate `kAudioHardwarePropertyDevices` and destroy any aggregate whose UID begins with the chronicle prefix. Muesli + Kaset both do this; otherwise Audio MIDI Setup accumulates orphan devices.

### Default-output-device change listener

Install an `AudioObjectPropertyListenerBlock` on `kAudioHardwarePropertyDefaultOutputDevice`. When the operator switches outputs (AirPods sleep/wake, Bluetooth swap, monitor unplug), the aggregate's clock anchor goes stale. The listener triggers full teardown + rebuild. Required for chronicle's 24/7 daemon profile; not needed for short-run apps.

### All-zero-buffer drift recovery (Apple Forum 825780)

Apple Developer Forum [thread 825780](https://developer.apple.com/forums/thread/825780) (macOS 26.5 Beta, MacBook Air M2) documents a long-session failure where `AudioDeviceIOProc` keeps firing but every PCM sample is exactly `0.0f` while system audio is still audible. Heartbeat, timestamps, and `kAudioProcessPropertyIsRunningOutput` all read normal. Workaround: full teardown and rebuild. Detection is hard because all-zero is indistinguishable from legitimate silence.

Chronicle mitigation:

* Run an RMS-on-rolling-window heartbeat as a `--verbose` diagnostic.
* If RMS has been zero for ≥ N minutes AND `kAudioProcessPropertyIsRunningOutput` reports active output on any non-self process, schedule a rebuild.
* Make the rebuild policy operator-configurable. False positives during legitimately quiet meetings are worse than silent dropouts in some workflows.

### Permission probing

There is no public TCC preflight API for `kTCCServiceAudioCapture`. Evidence:

* AudioCap (`AudioCap/ProcessTap/AudioRecordingPermission.swift`) uses **private TCC SPI** (`TCCAccessPreflight` and `TCCAccessRequest` from `/System/Library/PrivateFrameworks/TCC.framework`) behind a build flag.
* OMI source comment: "For Core Audio Taps, there's no explicit permission API. The system will prompt when we first try to create a tap."
* Kaset uses `CGPreflightScreenCaptureAccess()` as a proxy and notes the limitation.

Chronicle decision: rely on `NSAudioCaptureUsageDescription` + first-use prompt + first-valid-buffer watchdog. **No private TCC SPI in shipped builds.** A `--verbose` diagnostic should report what permission state is observable from public API.

### Synchronous-IPC reality

OMI source comment: "All CoreAudio HAL calls (CreateTap, CreateAggregateDevice, AudioDeviceStart) are synchronous IPC to coreaudiod via mach\_msg. After wake from sleep the daemon can take seconds to respond, blocking the caller." Dispatch all setup/teardown calls to a dedicated `DispatchQueue`, not the main thread or actor isolation boundary.

## Storage Recipe (FR-1)

This ADR originally evaluated Opus-in-CAF rotation while selecting the sysaudio
backend. ADR-0002 later superseded that storage decision after the real 6870 s
reference showed Opus WER drift. Current storage policy is:

* **Default durable sidecar:** ALAC-in-CAF written from analyzer-format PCM via
  `AVAudioFileALACSink`, rotated by audio duration.
* **Crash/recovery tier:** parallel `RollingPCMScratchSink` writes headerless raw
  analyzer PCM with `format.json`, so recent audio remains recoverable even if
  the active compressed segment loses finalization metadata.
* **Opus:** retained only as explicit opt-in/export; not a resilience default.
* **Source-native hi-fi storage:** deferred indefinitely. It does not meet the
  transcript-first product purpose and should only be revisited for a concrete
  hi-fi archive, source-separation, or non-SpeechAnalyzer post-processing
  requirement.

Historical Opus finding retained for context: on macOS 26.5,
`AudioFileWritePackets` did not flush CAF variable-bitrate packet tables
incrementally; exiting without `AudioFileClose` produced unreadable Opus CAF
(`ffprobe`: `Missing packet table`). This is why Chronicle treats compressed
sidecars as rotation/finalization artifacts and keeps raw scratch as the actual
recent-audio recovery tier.

## Operational fallback during transition

`Core/Audio/CoreAudioTapSource` has landed. The ad-hoc `/tmp/catap_record.swift` + `/tmp/catap_supervisor.sh` from the 2026-05-14 incident are historical evidence only; do not revive them as an operational fallback. Remaining cleanup from that incident is tracked in [`docs/STATUS.md`](../STATUS.md#pending-cleanup-from-2026-05-14-live-capture-incident).

## Consequences

### Positive

* `sysaudio` moves to the current macOS audio-specific API, validated on a real call.
* TCC copy changes from "Screen Recording folklore" to explicit System Audio Recording usage text via `NSAudioCaptureUsageDescription`.
* Implementation aligns with current production Swift references (\~13 surveyed projects).
* `SCStream` can remain available later for actual screen + video capture without carrying system-audio risk.
* Mic + sys can be hardware-synced via aggregate device in a future iteration (FR-4 streaming-diarize benefit).
* The `kTCCServiceAudioCapture` permission is independent of Developer ID signing; ad-hoc dev builds work identically to a future signed build.

### Negative

* CoreAudio tap implementation is lower-level and easier to leak resources. Mitigation: wrap tap + aggregate + IO proc in one `CoreAudioTapSource` owner with idempotent cleanup in every failure path; add startup orphan sweep.
* No public system-audio TCC preflight API. Mitigation: include `NSAudioCaptureUsageDescription`, rely on first-start prompt, keep a first-valid-buffer watchdog.
* Compressed sidecar resilience comes from rotation/finalization plus raw scratch, not from assuming the active CAF is crash-proof. Mitigation: ALAC/WAV/Opus rotate by duration; raw scratch remains the recent-audio recovery tier.
* Default-output-device change requires a listener + rebuild path. Mitigation: implement at the same time as `CoreAudioTapSource`.
* Long-session all-zero-buffer drift mode requires RMS heartbeat. Mitigation: ship as `--verbose` diagnostic first; promote to auto-rebuild after observing real-world cadence.
* `TCCPreflight.swift` should be renamed or narrowed: the screen-recording preflight remains useful only if SCStream is kept for future video work.

### Neutral

* `scripts/make-app.sh` remains useful because Tahoe TCC UI management works best with a bundled app identity.
* `Sources/Chronicle/Core/Audio/SysAudioSource.swift` becomes vestigial; delete after one release.
* The direct TCC.db writes performed during the incident (user + system DB) should be reverted; chronicle.app should be authorised through System Settings or first-launch prompt once the CoreAudio tap path lands.

## Acceptance Criteria

The new backend is accepted when, on the operator's macOS Tahoe 26.5 machine and with no manual TCC.db edits:

```gherkin
Given chronicle.app is built via scripts/make-app.sh with NSAudioCaptureUsageDescription in Info.plist
And no row exists for com.victor-software-house.chronicle in either TCC.db
When chronicle sysaudio is launched for the first time
Then macOS presents the System Audio Recording permission dialog
And after the operator approves, `chronicle sysaudio` captures non-zero PCM buffers within 1 s
And the operator sees the bundle listed under System Settings → Privacy & Security → System Audio Recording

Given the operator switches the default output device mid-capture (e.g. AirPods → speakers)
When the listener detects the change
Then the tap + aggregate device are rebuilt within 1 s
And captured audio resumes without operator action

Given chronicle sysaudio is killed with SIGKILL after 130 s
Then the previous segments (~60 s + ~60 s) are valid Opus CAF files playable in afplay
And the in-flight segment loses no more than its remaining 10 s of audio
And finals.sys.md contains all finals committed before the kill
```

Until those pass on a clean machine, ADR-0004 stays Accepted-pending-verification.

## Research-validation addendum (2026-05-15)

ADR-0004's central claims were independently validated against primary sources after acceptance. The decision (Option 2, CoreAudio process tap) holds. A first round of analysis (2026-05-15a) introduced three citation corrections + five new gotchas. A second deeper sweep (2026-05-15b) of 22+ actively-maintained 2026-dated repos surfaced two more corrections, five new convergence references, three new signed-app counter-examples, and a sixth gotcha (Tahoe device-change-storm). All folded back into this document below.

### What was confirmed

| Claim                                                                                                                        | Confirming source                                                                                                                                                                                                                                                                                                                                                   |
| ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS 15 Sequoia / 26 Tahoe SCStream audio requires a stable Apple Developer ID Team ID; ad-hoc signing is silently rejected | Apple DTS Engineer Quinn ("The Eskimo!") on [thread 819406](https://developer.apple.com/forums/thread/819406) and [thread 760112](https://developer.apple.com/forums/thread/760112). Quinn cites [TN3127 Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) as the authoritative spec. |
| CoreAudio process taps are Apple's canonical 2025-2026 sysaudio API                                                          | [Apple developer docs page](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) explicitly documents the recipe; current sample requires macOS 26.0+.                                                                                                                                                                  |
| All-zero buffer drift mode is real, reproducible, and unrecoverable without full teardown + rebuild                          | Apple Developer Forum [thread 825780](https://developer.apple.com/forums/thread/825780). No HAL property exists to distinguish data-path failure from legitimate silence; RMS heartbeat is the only practical detector.                                                                                                                                             |
| `kAudioSubTapDriftCompensationKey: true` is mandatory per sub-tap                                                            | Confirmed by muesli + blackbox + Apple docs page. (AudioTee omits it — known gap in that reference impl.)                                                                                                                                                                                                                                                           |
| Teardown order `Stop → DestroyIOProcID → DestroyAggregate → DestroyTap`                                                      | Confirmed identical across AudioCap, AudioTee, blackbox, spkrdump.                                                                                                                                                                                                                                                                                                  |
| CGWindowListCreateImage conflict with SCStream                                                                               | Confirmed in muesli migration commit [ada9493](https://github.com/pHequals7/muesli/commit/ada94936c0863e494305580cfceeaed8bd62fdeb).                                                                                                                                                                                                                                |
| TCC v2 build-hash invalidation reproduced in the wild                                                                        | [pasrom/meeting-transcriber #79](https://github.com/pasrom/meeting-transcriber/issues/79) — independent reporter hits the exact same symptom we hit; fixed by full TCC reset + re-add via the System Settings `+` button.                                                                                                                                           |
| CoreAudio tap is shipping in big-project production                                                                          | [LizardByte/Sunshine PR #4209](https://github.com/LizardByte/Sunshine/commit/0d3be0bb1ec2fc3d0bf3774dee834e98353e7e03) (2026-03-21) — game-streaming server with 30k+ stars adopts the tap API for macOS audio capture.                                                                                                                                             |

### Citation corrections

| Removed/weakened claim                                                   | Reality                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Action taken                                                                                                                                                                                          |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BasedHardware/omi` listed in the convergence list                       | omi's `SystemAudioCaptureService` uses ScreenCaptureKit `SCStream`, not CoreAudio tap. omi is distributed as a Developer-ID-signed app and does not hit the ad-hoc TCC gate. Counter-example, not converging evidence.                                                                                                                                                                                                                                                                                                                                  | Removed from Option 2 "Good, because…" list and from the Implementation Recipe convergence list. Kept in Related as a signed-app counter-example.                                                     |
| `sozercan/kaset` listed in the convergence list                          | Kaset does not capture system audio at all — it plays YouTube Music inside a `WKWebView`. The `ProcessTapHelper.swift` file in the repo is dead code or a vestigial experiment; the actual playback path is the WebView.                                                                                                                                                                                                                                                                                                                                | Removed from convergence list and Related references.                                                                                                                                                 |
| "13+ surveyed production apps converge"                                  | Actual verified count is 10+ (round-1) and 15+ (round-2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Tightened then extended after the round-2 survey.                                                                                                                                                     |
| `pHequals7/muesli` cited as having "migrated from SCK" (round-1 framing) | Muesli's main branch landed PR #50 with `CoreAudioSystemRecorder`, but it is **gated behind a `useCoreAudioTap` feature flag**. The shipping release `Muesli 0.6.5` (2026-04-30) still lists `System audio: ScreenCaptureKit (SCStream)` in its tech-stack table. The tap is wired but is not the default.                                                                                                                                                                                                                                              | Weakened to "feature-flag transitional" — still strong evidence for the tap recipe (their `CoreAudioSystemRecorder.swift` is one of the cleanest references) but not a clean post-migration codebase. |
| "Apple-blessed" framing implies WWDC25 promotes the tap                  | The [WWDC25 system audio sessions](https://developer.apple.com/wwdc25/) (251 "Enhance your app's audio recording capabilities", 277 "Bring advanced speech-to-text to your app with SpeechAnalyzer") market `SpeechTranscriber` + `SpeechAnalyzer` (transcription) and `AVCaptureSession` + `AudioDataOutput` (mic recording). **System audio capture via CoreAudio tap is NOT a WWDC25 marquee topic** — it lives in the standalone [docs page](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) only. | Reframed: "Apple-blessed via the canonical docs page" rather than "Apple-marketed". Tap remains the correct answer, just a quieter one.                                                               |

### New gotchas folded into the decision

1. **TCC v2 silently rejects ad-hoc rebuild grants.** Every new ad-hoc build has a different code signature hash. macOS Sequoia/Tahoe TCC keys grants by signature hash. Result: **TCC entries can appear granted in System Settings while being silently rejected at runtime.** This explains exactly why the 2026-05-14 direct `TCC.db` writes for `com.victor-software-house.chronicle` did not fix SCStream audio — the rows were valid but stale to `tccd`'s signature-hash check. Source: [UseStitch/stitch PR #153](https://github.com/UseStitch/stitch/pull/153), [CapSoftware/Cap #1722](https://github.com/CapSoftware/Cap/issues/1722). Operational mitigation: `tccutil reset ScreenCapture <bundle-id>` + `tccutil reset Microphone <bundle-id>` + `tccutil reset AudioCapture <bundle-id>` on every signing-hash change, then re-prompt. Productionising this for the dev workflow is a chronicle cleanup task (STATUS.md #10).

2. **Apple's canonical sample now requires macOS 26.0+.** The CoreAudio tap APIs (`CATapDescription`, `AudioHardwareCreateProcessTap`) have been present since macOS 14.2, but Apple bumped the sample's deployment target to 26.0 in the current docs page. Chronicle is Tahoe 26+ only, so this is aligned; older community references claiming "14.2+" or "14.4+" are still correct for the underlying API but stale relative to Apple's current minimum.

3. **Developer ID-signed binaries pay measurable TCC perf overhead on every SCStream call.** [Dominic Rodemer, "The macOS Notarization Performance Mystery"](https://blog.dominicrodemer.com/macos-notarization-performance-mystery/) (2026-01-27): every `SCShareableContent.excludingDesktopWindows()` and every `stream.updateConfiguration()` call invokes `tccd` which runs full cert chain validation + revocation checks for Developer-ID-signed binaries. Apple Development certs use a faster path. Architectural implication: even if chronicle paid for Apple Developer Program enrolment, SCStream would still be slower than CoreAudio tap per-call because the tap's aggregate device is a single setup cost rather than a per-call security boundary. Counterfactual scoreboard updated: SCStream drops from 7/10 to 6/10 when the Dev ID gate is hypothetically removed.

4. **AudioTee lacks drift compensation.** Verified via deepwiki on `makeusabrew/audiotee` codebase: the aggregate device dict in `AudioTapManager.setupAudioTap` does not include `kAudioSubTapDriftCompensationKey`. This is a known gap in the AudioTee reference impl. Chronicle's `CoreAudioTapSource` recipe (which does set the key) is therefore strictly stronger than AudioTee's. OMI's experience confirms the cost of omitting it: "without it the aggregate clock drifts and the system resamples on every IO cycle, producing periodic crackling in *all* system audio playback".

5. **Pre-allocated `AVAudioPCMBuffer` pool inside the IOProc.** `tenequm/blackbox` 0.7.0 explicitly added a pre-allocated PCM buffer pool because allocating inside the IOProc block violates real-time-thread safety. Chronicle's `CoreAudioTapSource` must adopt the same pattern: pre-allocate N buffers at start, use a lock-free ring to hand them between the IOProc thread and the consumer. Productionising this is STATUS.md cleanup item #11.

6. **Tahoe fires device-change notifications much more aggressively than Sequoia, and aggregate-device creation is itself a device-change event.** [Beingpax/VoiceInk PR #517](https://github.com/Beingpax/VoiceInk/pull/517) (5,000-star app, 2026-02-05): "On macOS Tahoe, the audio subsystem appears to fire device change notifications more aggressively, making this problem much worse than on previous macOS versions." Their bug: two device-change handlers raced, the second silently killed every recording on every notification (`[debug] handleDeviceChange: posting .toggleMiniRecorder`). [pablo-health/AudioCaptureKit](https://github.com/pablo-health/AudioCaptureKit) confirms the underlying surface: "Aggregate device creation fires device change notifications. AudioCaptureKit only stops recording if the selected mic actually disappeared." Implication for chronicle's `CoreAudioTapSource`: the `kAudioHardwarePropertyDefaultOutputDevice` listener must **not** trigger a rebuild for self-induced notifications from our own `AudioHardwareCreateAggregateDevice` call, and must only act on changes to the resolved default-output `AudioObjectID`, not on every property-changed event. Productionising this guard is STATUS.md cleanup item #12.

### Extended convergence list (round-2 survey 2026-05-15b)

Five additional verified CoreAudio-tap implementations surfaced in the deeper 2026-dated sweep:

| Repo                                                                                                            | Stars | Last push  | Notes                                                                                                                                                                                                                                                                                                                  |
| --------------------------------------------------------------------------------------------------------------- | ----: | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`pasrom/meeting-transcriber`](https://github.com/pasrom/meeting-transcriber)                                   |    22 | 2026-05-13 | The most chronicle-shaped architectural analogue found: dual mic+sys CATap, FluidAudio diarization (same model chronicle uses), per-5-second RMS heartbeat debug log (`[debug] App audio RMS (5s): … dBFS, samples=…, totalBytes=…`), output-device-change listener, automated E2E test against the real ASR pipeline. |
| [`paberr/ownscribe`](https://github.com/paberr/ownscribe)                                                       |    63 | 2026-03-08 | Python CLI orchestrator + Swift Core Audio Taps helper; auto-downloaded on first run. Explicit `coreaudio` vs `sounddevice` backend toggle.                                                                                                                                                                            |
| [`vorpus/D-Scribe`](https://github.com/vorpus/D-scribe)                                                         |     0 | 2026-04-06 | macOS 14.2+; two-channel `YOU` / `MEETING` model with explicit `Audio Capture` permission separate from screen recording.                                                                                                                                                                                              |
| [`r3dbars/transcripted`](https://github.com/r3dbars/transcripted)                                               |   n/a | 2026-05-04 | `SystemAudioCapture.swift # System audio via CoreAudio process taps`. Documents the threading model: `CoreAudio I/O callbacks → Real-time thread → No I/O, locks, allocations, or ObjC calls` — same constraint as chronicle's RT-safety requirement (gotcha #5).                                                      |
| [`LizardByte/Sunshine`](https://github.com/LizardByte/Sunshine/commit/0d3be0bb1ec2fc3d0bf3774dee834e98353e7e03) |  30k+ | 2026-03-21 | Game-streaming server. PR #4209 "feat(macOS): Capture audio on macOS using Tap API" — large-project signal that the tap API is production-ready outside the meeting-transcription niche.                                                                                                                               |

### Extended signed-app counter-examples (round-2)

Three additional currently-shipping apps that use `SCStream` and don't hit the ad-hoc TCC gate because they are Developer-ID-signed / Mac App Store distributed:

| Repo                                                                                    | Stars | Notes                                                                                                                                                                                                                                                    |
| --------------------------------------------------------------------------------------- | ----: | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`moonshine-ai/MoonshineNoteTaker`](https://github.com/moonshine-ai/MoonshineNoteTaker) |    78 | Mac App Store distributed, signed `.app`. Pattern matches omi exactly — SCK is the easier path when Dev ID is already in place.                                                                                                                          |
| [`bemmerzaal/Audido`](https://github.com/bemmerzaal/Audido)                             |     0 | macOS 26 Tahoe only; SwiftData + WhisperKit.                                                                                                                                                                                                             |
| [`turantekin/Parrot`](https://github.com/turantekin/Parrot)                             |     4 | Acknowledges the Sequoia identity issue in README: "Screen Recording permission is annoying — When running from Xcode, the binary gets re-signed each build, which can invalidate the permission." — same root cause; their workaround is manual re-add. |

The pattern is consistent: apps that can sign with Dev ID stay on SCStream out of inertia. Apps born on ad-hoc workflows go CoreAudio tap. Both shapes ship. Chronicle's ad-hoc dev workflow puts it firmly in the second camp.

### Modern implementation sweep (2026-05-17c)

A follow-up sweep prioritised 2026 / macOS 26+ references over older examples.
It found no reason to change Chronicle's backend choice. It did sharpen the
hardening backlog.

| Reference                                                                                                                             | Modernity signal                      | Relevant pattern                                                                                                                                                                        | Chronicle delta                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| [`tenequm/blackbox` 0.7.0](https://github.com/tenequm/blackbox/releases/tag/v0.7.0)                                                   | 2026-04-17, macOS 26.1+, Swift 6.2    | Replaced SCStream with CATap; hardware smoke test mode; output-device rebuild; drift compensation; pre-allocated `AVAudioPCMBuffer` pool; `actor` recorder with custom serial executor. | Confirms #74/#75 hardening: measure fan-out/backpressure, pre-allocate buffers, add stronger hardware smoke coverage.                     |
| [`pHequals7/muesli` CoreAudio migration](https://github.com/pHequals7/muesli/commit/ada94936c0863e494305580cfceeaed8bd62fdeb)         | 2026-04-16                            | SCStream → CoreAudio tap migration; `NSAudioCaptureUsageDescription`; tap creation triggers audio-capture permission; UID-string aggregate tap list; stale aggregate cleanup.           | Matches Chronicle's active path and TCC docs; reminder to keep stale-device cleanup + explicit permission wording.                        |
| [`LizardByte/Sunshine` PR #4209](https://github.com/LizardByte/Sunshine/commit/0d3be0bb1ec2fc3d0bf3774dee834e98353e7e03)              | 2026-03-21, 36k-star game-stream host | System-wide tap in a large production app; preallocated buffers; avoids ObjC/runtime calls and allocation in callback; unit tests around macOS audio layer.                             | Strongest scale signal; supports moving heavy conversion/fan-out work out of realtime callback if profiling shows pressure.               |
| [`obsfx/audiograb`](https://github.com/obsfx/audiograb)                                                                               | 2026-02-03 Swift CLI                  | Private aggregate + IOProc; callback writes Float32 PCM to lock-free ring; background writer drains every 10 ms; clear exit codes and TCC help.                                         | Confirms producer/consumer decoupling as likely next improvement; current Chronicle callback still converts/yields inline.                |
| [`sbetko/catap`](https://github.com/sbetko/catap)                                                                                     | 2026-01-29, current dev on macOS 26.2 | Python bindings + native dylib; preallocated native ring; bounded pending-buffer queue; callback runs on worker thread; documents sleep/wake/route-change gaps.                         | Useful negative evidence: long-running route/sleep cases remain hard even in focused libraries. Keep Chronicle rebuild/watchdog receipts. |
| [`pablo-health/AudioCaptureKit`](https://github.com/pablo-health/AudioCaptureKit)                                                     | 2026-02-21, Swift 6                   | CoreAudio taps + AVFoundation package; Capture → Processing → Storage abstraction; stereo mic/system mixing; encrypted chunk writer.                                                    | Reference only. It targets mixed hi-fi-ish storage, not Chronicle's analyzer-format ALAC + scratch recovery contract.                     |
| [`makeusabrew/audiotee`](https://github.com/makeusabrew/audiotee)                                                                     | 2025 active Swift CLI/library         | Simple reusable CATap CLI; exposed include/exclude/mute config; useful minimal setup reference.                                                                                         | Still useful but weaker than 2026 refs; lacks some drift/RT-safety hardening.                                                             |
| [`sbetko/catap`](https://github.com/sbetko/catap) / [`obsfx/audiograb`](https://github.com/obsfx/audiograb) / `audiotee` as libraries | 2025-2026                             | Small capture helpers exist, but none combine SpeechAnalyzer format negotiation, rotated ALAC, scratch repair, and Chronicle task semantics.                                            | No dependency adoption. ADR-0005 still holds.                                                                                             |

SpeechAnalyzer references from WWDC25 and Apple docs also match Chronicle's live
format policy: call `bestAvailableAudioFormat(compatibleWith:)`, convert live
buffers to that format, then yield `AnalyzerInput`. File-based analyzer APIs may
auto-convert whole files; live `AsyncStream<AnalyzerInput>` does not.

Net result: Chronicle is aligned with modern references on **API choice** and
**format policy**. Remaining gaps are implementation hardening, not architecture:
preallocated callback buffers (#75), measured sidecar fan-out/backpressure (#74),
converter tail drain (#77), hardware smoke automation, and eventual SCStream
retirement (#76).

### Counterfactual scoreboard (updated)

If the Apple Developer ID Team ID gate were hypothetically removed, the merit-only comparison shifts but the verdict stands:

| Option                               | Score (Dev ID gate active) | Score (counterfactual: gate removed) | Why changed                                                |
| ------------------------------------ | :------------------------: | :----------------------------------: | ---------------------------------------------------------- |
| 1. SCStream audio-only               |            1/10            |                 6/10                 | -1 from Dominic Rodemer's cert-chain-per-call perf finding |
| **2. CoreAudio process tap**         |          **9/10**          |               **9/10**               | unchanged — wins by 3 instead of 8                         |
| 3. Hybrid SCStream video + tap audio |            8/10            |                 9/10                 | only relevant if chronicle adds screen video               |
| 12. Developer ID enrolment           |            3/10            |                  n/a                 | gate removed by hypothesis                                 |

Even in the counterfactual world, CoreAudio tap wins on permission semantics, FR-4 hardware sync with mic, recoverable failure modes via RMS heartbeat, and per-call perf cost. The Dev ID gate makes the choice forced; removing it makes the choice merely correct.

## Related

* **PRD**: [`PRD-001: Resilient multi-source chronicle daemon`](../prd/PRD-001-resilient-multi-source-daemon.md)
* **ADRs**:
  * [`ADR-0001: Modular pipeline architecture`](ADR-0001-modular-pipeline-architecture.md)
  * [`ADR-0002: Audio storage format`](ADR-0002-audio-storage-format.md) — current ALAC-in-CAF plus raw scratch storage decision
* **Implementation files affected**:
  * `Info.plist`
  * `Sources/Chronicle/Core/Audio/SysAudioSource.swift` (deprecate, then delete)
  * `Sources/Chronicle/Core/Audio/CoreAudioTapSource.swift` (new)
  * `Sources/Chronicle/Core/Audio/TCCPreflight.swift` (narrow or delete)
  * `Sources/Chronicle/Core/Sinks/AVAudioFileALACSink.swift`, `RollingPCMScratchSink.swift`, and `OpusCAFSink.swift` (storage policy now owned by ADR-0002)
  * `Sources/Chronicle/Subcommands/SysAudio.swift`
  * `Tests/ChronicleTests/Audio/`
  * `Tests/ChronicleTests/Sinks/`
  * `AGENTS.md`, `README.md`, `docs/STATUS.md`
* **Apple references**:
  * [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  * [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos)
  * [Control access to screen and system audio recording on Mac](https://support.apple.com/en-afri/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/26/mac/26)
  * [Audio Input Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.audio-input)
  * [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
  * [macOS Tahoe 26 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
  * Apple Developer Forum [thread 825780](https://developer.apple.com/forums/thread/825780) — IOProc all-zero failure
  * Apple Developer Forum [thread 819406](https://developer.apple.com/forums/thread/819406) — SCStream permissions lost across builds
* **Community evidence**:
  * [CapSoftware/Cap #1722](https://github.com/CapSoftware/Cap/issues/1722) — SCStream + ad-hoc signing failure root cause (2026-04-09)
  * [trycua/cua #870](https://github.com/trycua/cua/issues/870) — Tahoe requires .app bundle for Privacy UI listing (2026-01-21)
  * [matthartman/ghost-pepper #21](https://github.com/matthartman/ghost-pepper/issues/21) — Hardened Runtime audio-input entitlement stripping (2026-04-06)
  * `insidegui/AudioCap` — [ProcessTap.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/ProcessTap.swift), [AudioRecordingPermission.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/AudioRecordingPermission.swift)
  * `BasedHardware/omi` — [SystemAudioCaptureService.swift](https://github.com/BasedHardware/omi/blob/main/desktop/Desktop/Sources/SystemAudioCaptureService.swift) (uses SCStream behind Developer-ID signing; counter-example, not converging evidence)
  * `pHequals7/muesli` — [CoreAudioSystemRecorder.swift](https://github.com/pHequals7/muesli/blob/main/native/MuesliNative/Sources/MuesliNativeApp/CoreAudioSystemRecorder.swift), migration commit [ada9493](https://github.com/pHequals7/muesli/commit/ada94936c0863e494305580cfceeaed8bd62fdeb)
  * `yazinsai/OpenOats` — [SystemAudioCapture.swift](https://github.com/yazinsai/OpenOats/blob/main/OpenOats/Sources/OpenOats/Audio/SystemAudioCapture.swift)
  * `argmaxinc/argmax-sdk-swift-playground` — [ProcessTapper.swift](https://github.com/argmaxinc/argmax-sdk-swift-playground/blob/main/Playground/Audio/ProcessTapper.swift) (WhisperKit integration)
  * `makeusabrew/audiotee` — [AudioTapManager.swift](https://github.com/makeusabrew/audiotee/blob/main/Sources/AudioTeeCore/Core/AudioTapManager.swift)
  * `atelier-socle/swift-capture-kit` — [PCM ring buffer fix](https://github.com/atelier-socle/swift-capture-kit/commit/15a9d1009ab8f4e1022ec9a36d4abb6f0df08882) (AAC-LC frame alignment, applies to Opus too)
  * `pablo-health/AudioCaptureKit` — [Repository](https://github.com/pablo-health/AudioCaptureKit)
  * `sbetko/catap` — [Python bindings + recording utilities](https://github.com/sbetko/catap)
  * `tenequm/blackbox` — [CATap + AVAudioEngine dual pipelines](https://github.com/tenequm/blackbox)
  * `AdelElo13/mac-control-mcp` — [TCC + .app bundle fix commit](https://github.com/AdelElo13/mac-control-mcp/commit/723ba0c5c33c56e35b2dd571fc343be5d4e575a9) (2026-04-17)
  * [Rogue Amoeba: MacOS 26 (Tahoe) Includes Important Audio-Related Bug Fixes](https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/) (2025-11-04) — independent confirmation that Tahoe 26.0 had broken audio capture paths and 26.1 fixed most of them
  * [Recording system audio in Electron on macOS](https://paynedigital.com/articles/recording-system-audio-electron-macos-approaches) (2025-10-24) — third-party analysis of CoreAudio tap vs Chromium getDisplayMedia
* **Storage references**:
  * IETF [draft-ietf-codec-oggopus-10](https://datatracker.ietf.org/doc/draft-ietf-codec-oggopus/10/) — Ogg-Opus framing spec
  * Apple [CAF File Specification](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_overview/CAF_overview.html) — Packet Table + Free chunk semantics
  * `alta/swift-opus`, `sbooth/opus-binary-xcframework`, `element-hq/swift-ogg`
