# ADR-0007 · Tahoe 26.5 CATap zero-buffer regression and Developer-ID signing path

* Status: **Proposed** (2026-05-20)
* Supersedes: none
* Amends: ADR-0004 (Tahoe system-audio capture), AGENTS.md robustness layer
* Owner: Victor

## Context

`chronicle sysaudio` uses `AudioHardwareCreateProcessTap` + private aggregate
device (the recipe documented in ADR-0004) to capture the system audio mix.
This worked at commit `e01e9d0` (2026-05-17 speed test: 6/6 runs survived
across device swaps).

As of 2026-05-20 on the same machine (macOS 26.5, build 25F71, M4 Pro), the
tap IOProc continues to fire at the expected cadence but every PCM sample in
every buffer is exactly `0.0f` while the system is producing audible output
through other apps (Music, Safari, `say`, `afplay`).

The bug is reproducible without any chronicle code via a minimal Swift program
(`chronicle-debug/minimal-tap.swift`) that performs the vanilla Apple recipe:

* `AudioHardwareCreateProcessTap` with `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `.unmuted`, private.
* `AudioHardwareCreateAggregateDevice` with `kAudioAggregateDeviceMainSubDeviceKey` = current default output UID.
* `AudioDeviceIOBlock` reading the aggregate.

Local repro on 2026-05-20, default output = `6C-12-70-05-43-1C:output` (AirPods Pro):

```
tap format: 48 000 Hz × 2 ch × 32-bit
[bufs= 64]  frames=512 ch=2 peak=0.0000 (-120.0 dB)
[bufs=128]  frames=512 ch=2 peak=0.0000 (-120.0 dB)
…
[bufs=1152] frames=512 ch=2 peak=0.0000 (-120.0 dB)
== done — bufs=1187 ==
```

Independent confirmation:

* Apple Developer Forums thread **825780**, "AudioHardwareCreateProcessTap delivers all-zero buffers while system audio is audible". Filed against macOS 26.5 Beta, MacBook Air M2. Symptoms match exactly. Apple has not shipped a fix in 26.5 GA.
* GitHub `pasrom/meeting-transcriber` issue **#79** (macOS Tahoe 26.4, MacBook Pro M2 Max). `CATapDescription` returns `peak=0, RMS=0` from the Microsoft Teams process.

Apple's reporter explicitly notes:

* IOProc cadence, timestamp deltas, default output UID, and `kAudioDevicePropertyDeviceIsRunningSomewhere` all remain normal during the affected periods.
* `kAudioProcessPropertyIsRunningOutput` reflects IO registration, **not** sample contribution.
* No published HAL property or notification distinguishes "tap data path stalled" from "the audio source is genuinely silent".

The bug affects ad-hoc-signed AND production Developer-ID-signed apps. It is
not a TCC issue and is not chronicle-specific.

## Apple's only known workaround

Full teardown and recreate of BOTH the tap and the aggregate device:

```
1. AudioDeviceStop(aggregateID, ioProcID)
2. AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
3. AudioHardwareDestroyAggregateDevice(aggregateID)
4. AudioHardwareDestroyProcessTap(tapID)
5. AudioHardwareCreateProcessTap(...)
6. AudioHardwareCreateAggregateDevice(...)
7. Create and start a new IOProc
```

Recreating only the aggregate OR only the IOProc does not recover the tap
data path. Restart cadence and zero-peak duration before triggering recreate
are the operator-tunable knobs.

## Why chronicle cannot just "do what CleanShot / OBS do"

Apps that capture system audio reliably on Tahoe today use Apple's
`ScreenCaptureKit` (SCStream) audio path. SCStream's audio capture is gated
behind Developer-ID-signed code on macOS Sequoia/Tahoe (see ADR-0004's
research-validation addendum: `BasedHardware/omi`, `MoonshineNoteTaker`,
`Audido`, `Parrot` all ship Dev-ID-signed bundles and use SCStream
successfully; the ad-hoc tier is gated out).

Chronicle is ad-hoc-signed, so SCStream is unavailable, and CATap (its only
ad-hoc-friendly alternative) is broken on 26.5. Until either Apple ships a
fix or chronicle ships a Dev-ID bundle, there is no working live-system-audio
path inside chronicle on this OS.

## Decision

Three tracks, ordered by leverage:

### Track A — defensive recovery cycle inside `CoreAudioTapSource`

Add an opt-in watchdog inside `Core/Audio/CoreAudioTapSource.swift`:

* track `lastNonZeroBufferAt` per IO callback (cheap; we already compute peak in `--verbose` mode — move it inline, sampled).
* if `peak == 0` for `--tap-watchdog-secs <N>` seconds AND `kAudioDevicePropertyDeviceIsRunningSomewhere` is `true` on the resolved default-output device AND at least one captured process reports `kAudioProcessPropertyIsRunningOutput == true`, run the 7-step teardown+recreate cycle.
* default `--tap-watchdog-secs = 0` (off). Recommended live setting: `30` (recovery loss bounded to one rotated CAF segment).
* every recreate emits a `control` event into the JSONL trace: `kind=tap.recovery`, `reason=zero-buffer-watchdog`, `previousZeroDurSecs=N`. So merge consumers see the gap.
* recreate is bounded by `withTimeout(seconds: 5)` and falls back to `stop()` on failure.
* known false-positive: a meeting with a long stretch of legitimate silence (everyone muted, on hold, etc.) will be torn down once. The recovery cost is ~50–100 ms of dropped audio plus the segment-rotation boundary; that's acceptable noise relative to losing the meeting.

This is the **only** workaround Chronicle can deploy unilaterally on the ad-hoc tier.

### Track B — Developer-ID signing for the production bundle

Pursue an Apple Developer Program enrollment for chronicle:

* annual fee: USD 99 (Apple Developer Program individual or organization).
* registration: <https://developer.apple.com/programs/enroll/>.
* enrol the bundle ID `com.victor-software-house.chronicle` against the issued Team ID.
* request a Developer ID Application certificate from <https://developer.apple.com/account/resources/certificates/>.
* update `scripts/make-app.sh` to `codesign --sign "Developer ID Application: <Name> (<TeamID>)"` instead of `--sign -`. Add a `--no-sign` fallback for CI / contributors without the cert.
* notarize via `notarytool` + staple. Workflow lives in a follow-up ADR-0008 (signing + notarization pipeline).
* once Dev-ID is in place, migrate `Core/Audio/CoreAudioTapSource` to an
  `Core/Audio/SCStreamSource` implementation behind the `AudioSource`
  protocol. CATap stays as the fallback for unsigned dev builds. Track
  exact accept criteria + parity gates in ADR-0008.

This is the long-term, durable fix. It is also the only way for chronicle to
exit the "ad-hoc fragility" tier that AGENTS.md cleanup item #10 + ADR-0004
research validation describe.

### Track D — coreaudiod-state recovery (no chronicle change, immediate)

Independent of Track A, an upstream observation (gist
[`metrovoc/0b5e3590c6069cf99b01559863bc2ce4`](https://gist.github.com/metrovoc/0b5e3590c6069cf99b01559863bc2ce4))
documents that Tahoe `coreaudiod` itself accumulates corrupted state over
hours-to-days of uptime. The CATap "zero-buffer" symptom is one expression
of that degraded state. Killing only `coreaudiod` does NOT recover — audio
client processes hold corrupted state and re-apply it. The recovery
sequence is:

```sh
# 1. kill all user processes that have CoreAudio loaded
lsof 2>/dev/null | grep CoreAudio | awk '{print $2}' | sort -un | xargs kill -9 2>/dev/null

# 2. kill Xcode/CoreSimulator (known exacerbators)
killall Xcode SimulatorTrampoline com.apple.CoreSimulator.CoreSimulatorService simdiskimaged 2>/dev/null

# 3. restart ALL audio daemons (not just coreaudiod)
sudo killall -9 coreaudiod audiomxd audioclocksyncd audioanalyticsd audioaccessoryd AudioComponentRegistrar
```

Promote this to `scripts/reset-audio.sh` alongside the existing
`scripts/reset-tcc.sh` placeholder (cleanup item #10). Recommend the
operator runs it before starting a `sysaudio` session that ran into the
zero-buffer state. Document the cadence: if a session has been clean for
< 24 h uptime, skip it; otherwise run before the meeting.

The macReports + Apple Community threads referenced below confirm this
applies to many users across M1–M4 hardware on Tahoe 26.0–26.5.

### Track C — operator workaround, documented

While Tracks A and B land:

* default output → "Chronicle Multi-Output" (private aggregate that fans audio to AirPods + BlackHole 2 ch).
* `ffmpeg -f avfoundation -i ":BlackHole 2ch"` records the loopback to rotated 60 s WAV segments.
* chronicle `transcribe` / `live` / `diarize` (which are unaffected by the
  Tahoe CATap bug — verified against `sys-master-clean.wav` 1346.62 s:
  226 segments at 87× rt, 6 speakers from `diarize` at 238× rt) runs on the
  finalized segments.
* requires one reboot to load the BlackHole HAL plugin and System Settings
  reach to grant Microphone TCC.

This is **already deployed** in the `~/transcripts/<session>/` watchdog stack
referenced in chronicle-elevenlabs-workflow.md and serves as the operational
floor until Track A and Track B land.

## Consequences

### Positive

* Track A: chronicle becomes resilient to the Apple bug without operator intervention. Worst case is one recovery cycle (~50–100 ms gap, segment boundary).
* Track B: chronicle joins the Dev-ID tier — SCStream becomes available, TCC stops drifting on every rebuild, future Apple gates around audio capture no longer block adhoc.
* Track C: high-stakes meeting capture has a working path **today**, no chronicle code change needed.

### Negative

* Track A teardown will fire on legitimately silent stretches and drop a small audio window. Acceptable; documented in the control event.
* Track A relies on a heuristic that may itself be invalidated by future Apple changes to `kAudioDevicePropertyDeviceIsRunningSomewhere` semantics.
* Track B: USD 99/year and one-time Dev-ID enrollment friction. SCStream
  migration is its own engineering project (ADR-0008).
* Track C requires reboot + BlackHole kernel extension. Loses the "single binary, no kext" property chronicle was designed around.

### Neutral

* Chronicle's offline pipeline (`transcribe`, `live --input file`, `diarize`,
  `merge`, `scratch-export`) and mic live path are unaffected and remain the
  primary working paths today.
* `scribe-cli` (ElevenLabs Scribe v2) covers high-accuracy post-processing
  independent of chronicle's capture stack.

## Verification expectations

For Track A acceptance:

* unit test in `Tests/ChronicleTests/Audio/CoreAudioTapSourceTests.swift` that drives the watchdog with a fake clock + injected zero-peak callback sequence; asserts the 7-step recovery is called exactly once and a `tap.recovery` control event lands in the trace.
* live smoke against the Tahoe 26.5 zero-buffer state: enable `--tap-watchdog-secs 30`, play audio, run for ≥ 5 min, expect the recovery event to fire and downstream finals to resume.
* end-to-end verification against the 2026-05-13 Zoom reference is unaffected (offline path).

For Track B acceptance:

* ADR-0008 (signing + notarization) ships first with its own acceptance criteria.

## References

* Apple Developer Forums — [thread 825780, "AudioHardwareCreateProcessTap delivers all-zero buffers while system audio is audible"](https://developer.apple.com/forums/thread/825780)
* GitHub — [`pasrom/meeting-transcriber` issue #79](https://github.com/pasrom/meeting-transcriber/issues/79)
* GitHub Gist — [`metrovoc/0b5e3590c6069cf99b01559863bc2ce4`, "macOS Tahoe audio glitch workaround"](https://gist.github.com/metrovoc/0b5e3590c6069cf99b01559863bc2ce4)
* Apple Community — [thread 256140785, "Audio glitches on Mac after macOS Tahoe update"](https://discussions.apple.com/thread/256140785)
* macReports — ["Audio Crackling, Pops, or Drop-Outs on Mac After Updating to macOS Tahoe (26)"](https://macreports.com/audio-crackling-pops-or-drop-outs-on-mac-after-updating-to-macos-tahoe-26/)
* Apple Developer Documentation — [`AudioHardwareCreateProcessTap(_:_:)`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)), [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
* Apple Developer Program — [enroll](https://developer.apple.com/programs/enroll/), [certificates](https://developer.apple.com/account/resources/certificates/list)
* ADR-0004 — Tahoe system-audio capture (original CATap recipe + research-validation addendum)
* AGENTS.md — robustness layer table (L1 bundle, L2 tap validation, L3 finalize timeout) and cleanup item #10 (`scripts/reset-tcc.sh`)
* Local repro: `<session-dir>/chronicle-debug/minimal-tap.swift` (vanilla Apple recipe, reproduces the regression)
