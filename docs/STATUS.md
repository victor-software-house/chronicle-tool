# chronicle-tool · roadmap + status

One-screen quick reference for "what's done, what's next, what's the
plan". Authoritative scope and acceptance criteria live in
[`PRD-001`](prd/PRD-001-resilient-multi-source-daemon.md); this is the
operator-facing dashboard.

Last refresh: 2026-05-13.

## Phase board

| # | Phase | FR | Status | Headline acceptance |
|---|---|---|---|---|
| **P0** | Modular refactor + test target | — | ✔ **done** | Byte-identical parity vs 2026-05-13 spike on `transcribe` + `diarize`; 13 `Core/` modules; 11 subcommands as thin veneers; `ChronicleTests` target wired. |
| **P7** | `chronicle sysaudio` subcommand | FR-3 | ✔ **done** | `SCStream` audio-only via `Core/Audio/SysAudioSource`; 4/4 TTS sentences captured exact; Info.plist `NSScreenCaptureUsageDescription` added. |
| **P11** | Opus production audio sink | FR-1 | ⏳ **in progress** | `Core/Sinks/OpusCAFSink` + `Core/Sinks/RollingPCMScratchSink` (ADR-0002 amended 2026-05-13: CAF default, not Ogg); WER delta ≤ 1 % vs WAV baseline on the 6870 s reference; default flips WAV → Opus-in-CAF after parity confirmed. |
| P3 | JSONL incremental trace | FR-2 | ⏳ pending | `Core/Sinks/JSONLTraceSink` via `AtomicFile.appendJSONLine`; `kill -9` mid-write leaves ≤ 1 torn line. |
| P4 | Locale auto-detect per ADR-0003 | FR-6 | ⏳ pending | `Core/Speech/LocaleResolver`; candidate-set restriction + 4-knob hysteresis; no "random Russian" by construction. |
| P5 | Live diarization | FR-4 | ⏳ pending | `Core/Audio/BufferMulticast` + `Core/Diarize/StreamingDiarizer`; speakerId merged into finals by audio range. |
| P6 | Live tagging via `--tag-every N` | FR-5 | ⏳ pending | `Core/Sinks/TagsJSONLSink` + cached `ContentTagger.tagText`; guardrail violations skip + continue. |
| P8 | `chronicle merge` | FR-7 | ⏳ pending | Chronological merge of N finals/JSONL traces preserving speaker labels. |
| P2 | `chronicle repair` | FR-8 | ⏸ de-prioritised | Only needed for `--audio-format wav` opt-in path; Opus + Ogg are crash-safe by container. |
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
| audio sidecar sink (`AudioSidecarSink`) | inline `AVAudioFile` WAV in subcommands (today) | `OpusCAFSink` + `RollingPCMScratchSink` (P11); `WAVSidecarSink` extracted as opt-in for export |
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
| P11 Opus production | #32 | next |
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
