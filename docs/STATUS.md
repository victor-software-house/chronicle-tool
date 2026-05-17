# chronicle-tool · roadmap + status

One-screen quick reference for "what's done, what's next, what's the
plan". Authoritative scope and acceptance criteria live in
[`PRD-001`](prd/PRD-001-resilient-multi-source-daemon.md); this is the
operator-facing dashboard.

Last refresh: 2026-05-17 — P11 ALAC production sidecar is implemented. Opus failed the 6870 s Zoom WER parity gate; ALAC with rounded Int16 source preserved decoded PCM/WER while shrinking the reference to ~91.3 MB. Native 32-bit-float public speech search did not produce a suitable longer transcripted corpus and no longer blocks the decision. `AVAudioFile` ALAC/CAF probe passed on the 6870 s reference (`alac`, `s16p`, 16 kHz mono, 91,316,352 bytes, `cmp-ok` against source PCM). Mic/sysaudio now default to composite ALAC + raw scratch, with audio-duration-based `--rotate-audio` segmenting for ALAC/WAV/Opus. Live mic smoke produced two readable ALAC CAF segments plus scratch PCM.

## Phase board

| # | Phase | FR | Status | Headline acceptance |
|---|---|---|---|---|
| **P0** | Modular refactor + test target | — | ✔ **done** | Byte-identical parity vs 2026-05-13 spike on `transcribe` + `diarize`; 13 `Core/` modules; 11 subcommands as thin veneers; `ChronicleTests` target wired. |
| **P7** | `chronicle sysaudio` subcommand | FR-3 | ✔ **done** | `SCStream` audio-only via `Core/Audio/SysAudioSource`; 4/4 TTS sentences captured exact; Info.plist `NSScreenCaptureUsageDescription` added. |
| **P11** | ALAC production audio sink | FR-1 | ✔ **done** | `Core/Sinks/AVAudioFileALACSink` + `Core/Sinks/RollingPCMScratchSink` (ADR-0002 amended 2026-05-16: ALAC default after Opus WER regression); `AVAudioFile` writer probe passed WER/byte-compare evidence. Default `--audio-format` is composite ALAC + scratch; `--rotate-audio` segments ALAC/WAV/Opus by audio duration. Live mic smoke produced two readable ALAC CAF segments plus scratch PCM. |
| P3 | JSONL incremental trace | FR-2 | ⏳ pending | `Core/Sinks/JSONLTraceSink` via `AtomicFile.appendJSONLine`; `kill -9` mid-write leaves ≤ 1 torn line. |
| P4 | Locale auto-detect per ADR-0003 | FR-6 | ⏳ pending | `Core/Speech/LocaleResolver`; candidate-set restriction + 4-knob hysteresis; no "random Russian" by construction. |
| P5 | Live diarization | FR-4 | ⏳ pending | `Core/Audio/BufferMulticast` + `Core/Diarize/StreamingDiarizer`; speakerId merged into finals by audio range. |
| P6 | Live tagging via `--tag-every N` | FR-5 | ⏳ pending | `Core/Sinks/TagsJSONLSink` + cached `ContentTagger.tagText`; guardrail violations skip + continue. |
| P8 | `chronicle merge` | FR-7 | ⏳ pending | Chronological merge of N finals/JSONL traces preserving speaker labels. |
| P2 | `chronicle repair` | FR-8 | ⏸ de-prioritised | Only needed for `--audio-format wav` opt-in path and unusual tail recovery; ALAC/CAF plus raw scratch reduces the default crash-repair surface. |
| P1 | WAV transitional rotation | FR-1 | ✘ skipped | Superseded by P11; was meant as a stepping stone toward Opus. |
| P9 | End-to-end verification | — | ⏳ pending | Run PRD-001 §15 appendix on a fresh session; capture receipts. |
| P10 | Post-impl documentation | — | ⏳ pending | Update README + research-notes + a verification spike doc with the final numbers. |

## What "done" means for each phase

P0 had eight sub-steps; every other phase is one logical task with the
acceptance criteria in PRD-001 §5 FR-X. The minimal evidence to mark a
phase done:

1. Build green (`swift build`).
2. Tests green (`swift test`).
3. Smoke-tested against the relevant real input (mic stream / sysaudio
   stream / 2026-05-13 reference WAV).
4. PRD-001 §15 acceptance criteria for the FR met (or the FR's own
   Gherkin scenarios pass).
5. Commit + push with a Conventional Commit message naming the FR.
6. Task marked `completed` via `TaskWrite` with the receipt summary in
   `metadata`.

## Pending cleanup from 2026-05-14 live-capture incident

A live call required immediate sys-audio recording. SCStream audio path on
Tahoe 26.5 refused to deliver real buffers for `chronicle.app` even after
manual TCC.db writes (both user + system). Fell back to an ad-hoc CoreAudio
process tap binary at `/tmp/catap_record.swift` plus a bash supervisor at
`/tmp/catap_supervisor.sh`. Recording worked. The bypass is **not**
production-clean and must be folded back into the repo.

| # | Cleanup item | Where |
|---|---|---|
| 1 | Productionise `/tmp/catap_record.swift` into `Core/Audio/CoreAudioTapSource` per ADR-0004 (replaces or co-exists with `SysAudioSource`) | `Sources/Chronicle/Core/Audio/` |
| 2 | Resilient WAV writes: header repatch every N s + `fsync` for every audio sidecar (mic + sys). Current `mic.wav` only has correct header on clean exit; SIGKILL leaves header at size 0 | `Core/Sinks/WAVSidecarSink.swift` |
| 3 | Segment rotation in supervisor / audio sink (currently one segment per process lifetime) — cuts crash window to ~1 segment | `Core/Sinks/` |
| 4 | Default-output-device change listener (`kAudioHardwarePropertyDefaultOutputDevice`) — rebuild tap on switch (AirPods sleep/wake, Bluetooth swap) | `Core/Audio/CoreAudioTapSource` |
| 5 | Remove the direct `tccd` TCC.db writes added during the incident; chronicle.app should be authorised through System Settings (or first-launch `CGRequestScreenCaptureAccess()` + CoreAudio tap permission prompt) | `~/Library/Application Support/com.apple.TCC/TCC.db`, `/Library/Application Support/com.apple.TCC/TCC.db` |
| 6 | Live transcription for sys path: pipe CoreAudio tap PCM into `SpeechAnalyzer` the same way `Mic.swift` does, so `finals.sys.md` is no longer empty | `Subcommands/SysAudio.swift` |
| 7 | Header-recovery helper for orphan WAVs (recovered the 200 MB `catap_sys.wav` by hand via Python; should be one of `chronicle repair` modes) | `Subcommands/Repair.swift` (FR-8) |
| 8 | Remove `CGRequestScreenCaptureAccess()` call from `SysAudioSource.start()` once the new tap backend lands; it was added during the incident and is irrelevant to CoreAudio taps | `Core/Audio/SysAudioSource.swift` |
| 9 | Garbage-collect `sys-HHMMSS.wav` 4 KB rejects from `~/Movies/pi-captures/sessions/20260514-112533-live/audio/` (already done locally, watch for regression once retry watchdog lands in repo) | session dir |
| 10 | Add a `scripts/reset-tcc.sh` dev helper that runs `tccutil reset ScreenCapture <bundle-id>` + `tccutil reset Microphone <bundle-id>` + `tccutil reset AudioCapture <bundle-id>` whenever the chronicle.app code-signing hash changes. macOS Sequoia/Tahoe TCC keys grants by signature hash; every ad-hoc rebuild silently invalidates prior grants (entries appear granted in System Settings but are rejected at runtime). This is the operational countermeasure for the same root cause that the 2026-05-14 direct TCC.db writes failed to address. Source: ADR-0004 research-validation addendum gotcha #1. | `scripts/reset-tcc.sh` |
| 11 | Pre-allocate `AVAudioPCMBuffer` pool inside `CoreAudioTapSource` IOProc. Allocating buffers inside the IOProc block violates real-time-thread safety (`tenequm/blackbox` 0.7.0 explicitly documents this as spec item D5). Pattern: pre-allocate N buffers at start, use a lock-free SPSC ring to hand them between the IOProc thread and the consumer task. Source: ADR-0004 research-validation addendum gotcha #5. | `Core/Audio/CoreAudioTapSource.swift` |
| 12 | Guard `kAudioHardwarePropertyDefaultOutputDevice` listener against **self-induced** device-change notifications. On Tahoe the audio subsystem fires device-change notifications much more aggressively than on Sequoia, and `AudioHardwareCreateAggregateDevice` is itself a device-change event. Naive rebuild-on-every-event = infinite rebuild loop. Pattern: cache the resolved default-output `AudioObjectID` after each rebuild and only act when the *resolved AudioObjectID* changes — not on every property-changed callback. References: [Beingpax/VoiceInk PR #517](https://github.com/Beingpax/VoiceInk/pull/517) (Tahoe notification storm), [pablo-health/AudioCaptureKit README](https://github.com/pablo-health/AudioCaptureKit) (aggregate-device-creation self-fires). Source: ADR-0004 research-validation addendum gotcha #6. | `Core/Audio/CoreAudioTapSource.swift` |

Live session being captured during the incident lives at:
`~/Movies/pi-captures/sessions/20260514-112533-live/`.

## Robustness layer (audio pipeline)

Three defensive layers prevent the macOS-Tahoe SCStream + audio-TCC
failure mode that previously hung the daemon at "stopping..." forever:

| Layer | Lives in | Catches |
|---|---|---|
| L1 preflight | `Core/Audio/TCCPreflight.swift` | TCC denied at known APIs (CGPreflightScreenCaptureAccess, AVAudioApplication recordPermission). Fails before any blocking syscall. |
| L2 first-valid-buffer watchdog (5 s) | `Core/Audio/SysAudioSource.swift` | SCStream silently delivering placeholder buffers when audio TCC denied for the binary identity. Throws `audioCaptureSilent`. |
| L3 bounded analyzer finalize (5 s + 2 s) | `Subcommands/Mic.swift` + `Subcommands/SysAudio.swift` | SpeechAnalyzer hung at shutdown after degenerate input. Falls through to `cancelAndFinishNow`. |

Production operator path requires a proper `.app` bundle (built via
`scripts/make-app.sh`) so that codesign binds the Info.plist and macOS
TCC resolves a stable identity. See AGENTS.md.

## What's plugged in vs what's still abstract

`Core/` ships these protocols today; everything below is composition:

| Protocol | Today's impls | Future impls |
|---|---|---|
| `AudioSource` | `MicAudioSource` (AVAudioEngine), `SysAudioSource` (SCStream) | `FileAudioSource` (P5 testing); RTSP / Bluetooth (post-PRD) |
| `TranscriptionSink` | `LiveFileSink`, `FinalsAppendSink` | `JSONLTraceSink` (P3), `TagsJSONLSink` (P6) |
| audio sidecar sink (`AudioSidecarSink`) | inline `AVAudioFile` WAV in subcommands (today) | `AVAudioFileALACSink` + `RollingPCMScratchSink` (P11); `WAVSidecarSink` extracted as opt-in for debug/export; `OpusCAFSink` retained opt-in only; `ExtAudioFile` ALAC fallback only if `AVAudioFile` regresses |
| `OfflineDiarizing` | `OfflineDiarizer` (FluidAudio VBx) | — |
| (planned) `StreamingDiarizing` | — | `StreamingDiarizer` (FluidAudio Sortformer, P5) |
| `ContentTagger.tagText` / `Summarizer.summarizeText` | cached via `ModelHost.shared` | — |

## How to pick the next thing to do

Default order is the table above. If you have a real reason to deviate:

- The protocol-oriented core (ADR-0001) means **any single phase is
  cheap to land** because every other phase composes against the same
  protocols.
- Phases that prerequisite each other are explicit:
  - P5 (live diarize) needs `BufferMulticast`, which P11 (Opus + scratch)
    also benefits from. Landing P11 first stabilises the fan-out under
    the audio thread.
  - P6 (live tagging) reads `TranscriptionSink` finals; it composes onto
    any P3 / P4 / P5 outcome without coupling.
  - P9 (verification) needs every other FR. Last.

## Where to look first when something is wrong

| Symptom | First file to read |
|---|---|
| Build fails | `Package.swift` (linker flags / `unsafeFlags` for Info.plist embed) + the file the compiler points to |
| Subcommand missing from `--help` | `Sources/Chronicle/Chronicle.swift` (dispatch list) |
| `mic` runs but no transcription | mic TCC at parent app + `MicAudioSource` callback running + `analyzerFormat` mismatch |
| `sysaudio` runs but `audio.wav` is silent | Screen Recording TCC at parent app — run with `--verbose` to see per-buffer peak amplitude |
| Diarize results differ from spike | `OfflineDiarizer` model version (FluidAudio `DiarizerModels.downloadIfNeeded`) — receipts assume the 2026-05-13 model version |
| Tag / Summarize errors with "unavailable" | Apple Intelligence toggle in System Settings; `ModelHostError.remediation` carries the user-visible hint |
| Spec doc validation fails | `specdocs_validate` for the exact path + line |

## Task-graph cheatsheet

Open phases map to bare numeric task IDs in the Pi task tracker:

| Phase | Task | Status |
|---|---|---|
| P0 step 1-8 | #31 (umbrella) + #33-#39 | ✔ |
| P7 sysaudio | #27 | ✔ |
| Doc hygiene | #41 | ✔ |
| P11 ALAC production | #32 | next |
| P3 JSONL | #23 | open |
| P4 LocaleResolver | #24 | open |
| P5 streaming diarize | #25 | open |
| P6 live tagging | #26 | open |
| P8 merge | #28 | open |
| P2 repair | #22 | de-prioritised |
| P1 WAV transitional | #21 | skipped |
| P9 verification | #29 | open |
| P10 docs receipts | #30 | open |

Use `TaskRead taskIds=["<id>"]` for full acceptance criteria; use
`TaskRead` with no args to list everything.
