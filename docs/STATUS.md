# chronicle-tool · roadmap + status

One-screen quick reference for "what's done, what's next, what's the
plan". Authoritative scope and acceptance criteria live in
[`PRD-001`](prd/PRD-001-resilient-multi-source-daemon.md); this is the
operator-facing dashboard.

Last refresh: 2026-05-17 — `chronicle sysaudio` now uses `CoreAudioTapSource` (CoreAudio process tap + private aggregate device) per [ADR-0004](adr/ADR-0004-tahoe-system-audio-capture.md), replacing the SCStream path in the CLI. Live smoke through `chronicle.app` captured TTS via CoreAudio tap, emitted a final transcript, wrote readable ALAC-in-CAF, and wrote raw scratch PCM. P11 ALAC production sidecar is implemented and the reuse boundary is documented in [ADR-0005](adr/ADR-0005-audio-sidecar-reuse-boundary.md). Opus failed the 6870 s Zoom WER parity gate; ALAC with rounded Int16 source preserved decoded PCM/WER while shrinking the reference to ~91.3 MB. `chronicle scratch-export` automates raw-PCM scratch recovery to WAV or ALAC-in-CAF.

## Phase board

| # | Phase | FR | Status | Headline acceptance |
|---|---|---|---|---|
| **P0** | Modular refactor + test target | — | ✔ **done** | Byte-identical parity vs 2026-05-13 spike on `transcribe` + `diarize`; 13 `Core/` modules; 11 subcommands as thin veneers; `ChronicleTests` target wired. |
| **P7** | `chronicle sysaudio` subcommand | FR-3 | ✔ **done** | `CoreAudioTapSource` via CoreAudio process tap (`CATapDescription` + private aggregate device) feeds the same `SpeechAnalyzer` pipeline as mic; live TTS smoke produced a final transcript and wrote readable ALAC + scratch sidecars. |
| **P11** | ALAC production audio sink | FR-1 | ✔ **done** | `Core/Sinks/AVAudioFileALACSink` + `Core/Sinks/RollingPCMScratchSink` (ADR-0002 amended 2026-05-16: ALAC default after Opus WER regression; ADR-0005 documents the reuse-boundary audit); `AVAudioFile` writer probe passed WER/byte-compare evidence. Default `--audio-format` is composite ALAC + scratch; `--rotate-audio` segments ALAC/WAV/Opus by audio duration. Live mic smoke produced two readable ALAC CAF segments plus scratch PCM. |
| **P2a** | Scratch export recovery | FR-8 | ✔ **done** | `chronicle scratch-export <scratch-dir> -o recovered.wav|.caf` reads `format.json`, validates canonical interleaved raw PCM, requires contiguous `.pcm` segments, trims partial trailing frames, and writes WAV or ALAC-in-CAF. |
| P3 | JSONL incremental trace | FR-2 | ⏳ pending | `Core/Sinks/JSONLTraceSink` via `AtomicFile.appendJSONLine`; `kill -9` mid-write leaves ≤ 1 torn line. |
| P4 | Locale auto-detect per ADR-0003 | FR-6 | ⏳ pending | `Core/Speech/LocaleResolver`; candidate-set restriction + 4-knob hysteresis; no "random Russian" by construction. |
| P5 | Live diarization | FR-4 | ⏳ pending | `Core/Audio/BufferMulticast` + `Core/Diarize/StreamingDiarizer`; speakerId merged into finals by audio range. |
| P6 | Live tagging via `--tag-every N` | FR-5 | ⏳ pending | `Core/Sinks/TagsJSONLSink` + cached `ContentTagger.tagText`; guardrail violations skip + continue. |
| P8 | `chronicle merge` | FR-7 | ⏳ pending | Chronological merge of N finals/JSONL traces preserving speaker labels. |
| P2b | Legacy WAV tail repair | FR-8 | ⏳ pending | `chronicle repair <wav>` rewrites malformed/stale WAV headers for old incident artefacts and `--audio-format wav` opt-in tails. |
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
`/tmp/catap_supervisor.sh`. Recording worked. The bypass has now been folded
into `Core/Audio/CoreAudioTapSource`; remaining cleanup is tracked below.

| # | Cleanup item | Status | Where |
|---|---|---|---|
| 1 | Productionise `/tmp/catap_record.swift` into `Core/Audio/CoreAudioTapSource` per ADR-0004 | ✔ done | `Sources/Chronicle/Core/Audio/CoreAudioTapSource.swift` |
| 2 | Resilient WAV writes: header repatch every N s + `fsync` for every audio sidecar (mic + sys). Current `mic.wav` only has correct header on clean exit; SIGKILL leaves header at size 0 | pending / superseded for default ALAC + scratch | `Core/Sinks/WAVSidecarSink.swift` |
| 3 | Segment rotation in supervisor / audio sink — cuts crash window to ~1 segment | ✔ done for ALAC/WAV/Opus via `--rotate-audio` | `Core/Sinks/AudioSidecarCombinators.swift` |
| 4 | Default-output-device change listener (`kAudioHardwarePropertyDefaultOutputDevice`) — rebuild tap on switch (AirPods sleep/wake, Bluetooth swap) | ✔ done with resolved-ID guard | `Core/Audio/CoreAudioTapSource.swift` |
| 5 | Remove the direct `tccd` TCC.db writes added during the incident; chronicle.app should be authorised through System Settings | pending operator cleanup | `~/Library/Application Support/com.apple.TCC/TCC.db`, `/Library/Application Support/com.apple.TCC/TCC.db` |
| 6 | Live transcription for sys path: pipe CoreAudio tap PCM into `SpeechAnalyzer` the same way `Mic.swift` does, so `finals.sys.md` is no longer empty | ✔ done | `Subcommands/SysAudio.swift` |
| 7 | Header-recovery helper for orphan WAVs (recovered the 200 MB `catap_sys.wav` by hand via Python; should be one of `chronicle repair` modes) | pending P2b | `Subcommands/Repair.swift` (FR-8) |
| 8 | Remove `CGRequestScreenCaptureAccess()` from the active sysaudio path once the new tap backend lands | ✔ done by switching CLI to `CoreAudioTapSource`; deprecated `SysAudioSource` still carries the legacy ScreenCaptureKit prompt path until #76 removes it | `Subcommands/SysAudio.swift`, `Core/Audio/SysAudioSource.swift` |
| 9 | Garbage-collect `sys-HHMMSS.wav` 4 KB rejects from `~/Movies/pi-captures/sessions/20260514-112533-live/audio/` | done locally; watch for regression | session dir |
| 10 | Add a `scripts/reset-tcc.sh` dev helper that runs `tccutil reset ScreenCapture <bundle-id>` + `tccutil reset Microphone <bundle-id>` + `tccutil reset AudioCapture <bundle-id>` whenever the chronicle.app code-signing hash changes | pending | `scripts/reset-tcc.sh` |
| 11 | Pre-allocate `AVAudioPCMBuffer` pool inside `CoreAudioTapSource` IOProc; current code still materialises/converts per callback and is acceptable only as a first productionised source | pending hardening | `Core/Audio/CoreAudioTapSource.swift` |
| 12 | Guard `kAudioHardwarePropertyDefaultOutputDevice` listener against self-induced device-change notifications | ✔ done with cached resolved default-output `AudioObjectID` | `Core/Audio/CoreAudioTapSource.swift` |

Live session being captured during the incident lives at:
`~/Movies/pi-captures/sessions/20260514-112533-live/`.

## Robustness layer (audio pipeline)

Three defensive layers prevent live audio capture failures from hanging the daemon:

| Layer | Lives in | Catches |
|---|---|---|
| L1 stable bundle identity | `scripts/make-app.sh` + `Info.plist` | TCC prompts/grants for Microphone and System Audio Recording attach to `chronicle.app`, not a transient bare binary. |
| L2 first-valid-buffer watchdog (5 s) | `Core/Audio/CoreAudioTapSource.swift` | Tap startup with no valid PCM flow (missing System Audio Recording grant, dead aggregate, or output routing issue). Throws `audioCaptureSilent`. |
| L3 bounded analyzer finalize (5 s + 2 s) | `Subcommands/Mic.swift` + `Subcommands/SysAudio.swift` | SpeechAnalyzer hung at shutdown after degenerate input. Falls through to `cancelAndFinishNow`. |

Production operator path requires a proper `.app` bundle (built via
`scripts/make-app.sh`) so that codesign binds the Info.plist and macOS
TCC resolves a stable identity. See AGENTS.md.

## What's plugged in vs what's still abstract

`Core/` ships these protocols today; everything below is composition:

| Protocol | Today's impls | Future impls |
|---|---|---|
| `AudioSource` | `MicAudioSource` (AVAudioEngine), `CoreAudioTapSource` (CoreAudio process tap), `SysAudioSource` (deprecated SCStream fallback not used by CLI) | `FileAudioSource` (P5 testing); RTSP / Bluetooth (post-PRD) |
| `TranscriptionSink` | `LiveFileSink`, `FinalsAppendSink` | `JSONLTraceSink` (P3), `TagsJSONLSink` (P6) |
| audio sidecar sink (`AudioSidecarSink`) | `AVAudioFileALACSink` + `RollingPCMScratchSink` default; `WAVSidecarSink` and `OpusCAFSink` opt-in | source-native hi-fi sidecar is deferred indefinitely / watchlist only (#79); `ExtAudioFile` ALAC fallback only if `AVAudioFile` regresses |
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
| `sysaudio` runs but `audio.caf` is silent | System Audio Recording TCC for `chronicle.app`, default output routing, then `CoreAudioTapSource` verbose peak diagnostics |
| Diarize results differ from spike | `OfflineDiarizer` model version (FluidAudio `DiarizerModels.downloadIfNeeded`) — receipts assume the 2026-05-13 model version |
| Tag / Summarize errors with "unavailable" | Apple Intelligence toggle in System Settings; `ModelHostError.remediation` carries the user-visible hint |
| Spec doc validation fails | `specdocs_validate` for the exact path + line |

## Task-graph cheatsheet

Open phases map to bare numeric task IDs in the Pi task tracker:

| Phase | Task | Status |
|---|---|---|
| P7 sysaudio | #27 | archived/done |
| P11 ALAC production | #32 | archived/done |
| P2a scratch export | #22 | done |
| P1 WAV transitional reconciliation | #21 | open |
| P3 JSONL | #23 | open |
| P4 LocaleResolver | #24 | open |
| P5 streaming diarize | #25 | open |
| P6 live tagging | #26 | open |
| P8 merge | #28 | open |
| P9 verification | #29 | open |
| P10 docs receipts | #30 | open |
| CoreAudioTapSource cleanup | #55 | done |
| Scratch fsync policy | #72 | open |
| Active ALAC CAF tail repair research | #73 | open |
| Sidecar fanout profiling | #74 | done — see [`spikes/2026-05-17-sidecar-fanout-profile.md`](../spikes/2026-05-17-sidecar-fanout-profile.md) |
| Scratch allocation profiling | #75 | done — see [`spikes/2026-05-17-scratch-allocation-profile.md`](../spikes/2026-05-17-scratch-allocation-profile.md) |
| Retire deprecated SCStream sysaudio source | #76 | open |
| Drain BufferConverter residual frames on stop | #77 | open |
| Source-native hi-fi audio sidecar watchlist | #79 | deferred indefinitely |

Use `TaskRead taskIds=["<id>"]` for full acceptance criteria; use
`TaskRead` with no args to list everything.
