# chronicle-tool · roadmap + status

One-screen quick reference for "what's done, what's next, what's the
plan". Authoritative scope and acceptance criteria live in
[`PRD-001`](prd/PRD-001-resilient-multi-source-daemon.md); this is the
operator-facing dashboard. New governed work starts in `.kiro/specs/`; legacy
PRD/ADR/architecture docs remain source references until migrated.

Last refresh: 2026-05-28 — `/Applications/chronicle.app` signed with Apple
Development Team ID `CXLYTY8DMR` has verified live `chronicle sysaudio` capture
through CoreAudio taps. Proof receipts from live `say` smokes showed nonzero
`sessionPeak` values up to 25251 and transcript text in `finals.md` / `live.md`.
The private TCC preflight can still report DENIED from launcher context; that
probe is advisory only. Runtime PCM peak plus transcript output is the capture
authority. Chronicle sysaudio follows the current default output directly and
does not require BlackHole 2ch or a Multi-Output Device for normal operation.

The active cleanup is governed by
[`.kiro/specs/sysaudio-runtime-hardening`](../.kiro/specs/sysaudio-runtime-hardening/):
fix advisory TCC warning text, debounce default-output rebuilds, and split tap
diagnostics by channel/verbosity. Earlier 2026-05-18 status remains below for
functional-batch history.

Sysaudio/diarize smoke on 6-speaker fixture (6× speeds) was clean: no segfaults, 1.00x/1.25x/1.50x/2.00x speech quality near-perfect-to-good, 2.50x degraded, 3.00x unusable; all runs recovered stable speaker tags across dynamic output-device changes.

Throughput: 51.9 s live audio = 51 `Sortformer process()` calls, ~0.98/s. `/usr/bin/time -lh` latest: 5.45 s user + 1.56 s sys over 71.09 s wall (~10% of one M4 core), 544 MB max RSS; headless powermetrics: +~141 mW ANE above baseline. `transcriptionLatencyMs` is now recorded on each result and summarized by live stderr (`[source.latency ...]`; recent avg ≈ 389 ms, p95 838 ms on 215-result smoke).

The recurring single `E5RT encountered an STL exception. msg = unordered_map::at: key not found.` remains one non-fatal Apple ANE/CoreML warning during first Sortformer inference. Tracked as #99; no chronicle-side fix identified. Earlier same-day work replaced SCStream sysaudio with `CoreAudioTapSource` per [ADR-0004](adr/ADR-0004-tahoe-system-audio-capture.md); P11 ALAC production sidecar remains default per [ADR-0005](adr/ADR-0005-audio-sidecar-reuse-boundary.md).

## Phase board

| # | Phase | FR | Status | Headline acceptance |
|---|---|---|---|---|
| **P0** | Modular refactor + test target | — | ✔ **done** | Byte-identical parity vs 2026-05-13 spike on `transcribe` + `diarize`; 13 `Core/` modules; 11 subcommands as thin veneers; `ChronicleTests` target wired. |
| **P7** | `chronicle sysaudio` subcommand | FR-3 | ✔ **done** | `CoreAudioTapSource` via CoreAudio process tap (`CATapDescription` + private aggregate device) feeds the same `SpeechAnalyzer` pipeline as mic; live TTS smoke produced a final transcript and wrote readable ALAC + scratch sidecars. |
| **P11** | ALAC production audio sink | FR-1 | ✔ **done** | `Core/Sinks/AVAudioFileALACSink` + `Core/Sinks/RollingPCMScratchSink` (ADR-0002 amended 2026-05-16: ALAC default after Opus WER regression; ADR-0005 documents the reuse-boundary audit); `AVAudioFile` writer probe passed WER/byte-compare evidence. Default `--audio-format` is composite ALAC + scratch; `--rotate-audio` segments ALAC/WAV/Opus by audio duration. Live mic smoke produced two readable ALAC CAF segments plus scratch PCM. |
| **P2a** | Scratch export recovery | FR-8 | ✔ **done** | `chronicle scratch-export <scratch-dir> -o recovered.wav|.caf` reads `format.json`, validates canonical interleaved raw PCM, requires contiguous `.pcm` segments, trims partial trailing frames, and writes WAV or ALAC-in-CAF. |
| **P3** | JSONL incremental trace | FR-2 | ✔ **done** | `Core/Sinks/JSONLTraceSink` appends source-aware `trace.jsonl`; locked append prevents multi-process line interleaving; torn trailing line recovery; schema is spine for merge/diarize/locale. |
| P8 | `chronicle merge` | FR-7 | ✔ **done** | `Subcommands/Merge.swift` reads N source-aware `trace.jsonl` and/or `finals.md` inputs, sorts by wallclock with stable tie-breaks, preserves source/locale/speaker labels; default `log` output, optional `--format markdown` table. |
| P5 | Live diarization | FR-4 | ✔ **done** | `Core/Audio/BufferMulticast.swift` fan-out, `Core/Diarize/StreamingDiarizer.swift` with `SortformerStreamingDiarizer` and `DiarizationTimelineLookup`; `--diarize` wired into `mic` and `sysaudio`; speakerId in JSONL trace + `[Sx]` finals.md prefix. |
| P4 | Locale auto-detect per ADR-0003 | FR-6 | ▲ **partial** | `Core/Speech/LocaleResolver` shipped: candidate-set restriction, 4-knob hysteresis, hot-swap via `setModules()`, BCP-47 normalization, switch-control trace events. **Detection mechanism broken** — NLLanguageRecognizer on text fails when initial locale is wrong (chicken-and-egg: wrong locale → gibberish text → detector can't identify real language). [ADR-0006](adr/ADR-0006-audio-level-language-detection.md) supersedes with WhisperKit audio-level detection. Pin mode (`--locale pt-BR`) works correctly. |
| P6 | Live tagging via `--tag-every N` | FR-5 | ⏳ after functional batch | `Core/Sinks/TagsJSONLSink` + cached `ContentTagger.tagText`; guardrail violations skip + continue. |
| P2b | Legacy WAV tail repair | FR-8 | ⏳ pending | `chronicle repair <wav>` rewrites malformed/stale WAV headers for old incident artefacts and `--audio-format wav` opt-in tails. |
| P1 | WAV transitional rotation | FR-1 | ✘ skipped | Superseded by P11; was meant as a stepping stone toward Opus. |
| P9 | End-to-end verification | — | ⏳ pending | Run PRD-001 §15 appendix on a fresh session; capture receipts. |
| P10 | Post-impl documentation | — | ⏳ pending | Update README + research-notes + a verification spike doc with the final numbers. |

## Functional batch checkpoint

Current priority batch state:

1. **FR-2 / #23 — done.** Commit `36375a5` added the source-aware JSONL trace spine, locked append primitive, monotonic clock helper, `TranscriptionSink.didReceiveResult`, CLI wiring for `mic` / `sysaudio` / `live`, tests, docs, and smoke receipts.
2. **FR-7 / #28 — done.** `chronicle merge` lands `Subcommands/Merge.swift` with `MergeService`, `FinalsMarkdownReader`, and `MergeRenderer` (log/markdown), plus `Tests/ChronicleTests/Subcommands/MergeTests.swift`. Consumes `trace.jsonl` (preferred) and legacy `finals.md` together; preserves source/locale/speaker labels; tolerates torn trailing JSONL lines with a stderr warning.
3. **FR-4 / #25 — done.** `Core/Audio/BufferMulticast.swift` fans the source PCM stream to sidecar + diarizer subscribers with a bounded per-subscriber `.bufferingNewest` queue. `Core/Audio/PCMFloatConverter.swift` handles the hot PCM-to-16-kHz-mono-Float path with Int16 / Float32 fast paths plus an `AVAudioConverter` fallback. `Core/Diarize/StreamingDiarizer.swift` exposes the `StreamingDiarizing` protocol, the pure `DiarizationTimelineLookup` value type for midpoint speaker lookup, `StreamingDiarizerBackend` for CoreML-free tests, and the `SortformerStreamingDiarizer` actor that loads FluidAudio Sortformer CoreML lazily, ingests converted buffers, throttles `process()` every ~1 s, and refreshes the lookup snapshot. `Mic.swift` and `SysAudio.swift` now accept `--diarize`; on each result they query `speakerId(forRange:)` and pass it into `TranscriptionSink.didReceiveResult`, so `JSONLTraceSink` records it and `FinalsAppendSink` prefixes finals with `[S0]`, `[S1]`, etc. Live receipts: Sarah + George fixture yielded correct S0/S1 labels in both mic and sysaudio, merge preserved speakers, realtime sysaudio stayed at ~1 process/sec with ~10% of one M4 core and measurable ANE rail activity. Speech-end-to-transcript latency is now measured live: latest sysaudio smoke reported avg 389 ms, p95 838 ms, max 1469 ms across 215 result events.
4. **FR-6 / #24 — partial.** `Core/Speech/LocaleResolver` and CLI wiring shipped: `--locale auto`/`--locale auto:<candidates>`, hot-swap via `SpeechAnalyzer.setModules()`, BCP-47 normalization, ambiguous base-language rejection, auto:* unconstrained mode, and per-decision control events in trace. **Detection mechanism is non-functional:** NLLanguageRecognizer on transcription text cannot detect the real language when the initial locale is wrong because SpeechTranscriber produces phoneme-hallucinated gibberish, not degraded-but-recognizable text. [ADR-0006](adr/ADR-0006-audio-level-language-detection.md) proposes replacing the detection signal with WhisperKit audio-level language identification. Pin mode (`--locale pt-BR`) works correctly and is the recommended workaround until ADR-0006 is implemented.
5. **Post-change robustness hardening — done.** Device switch crash path fixed by buffer-copying per-subscriber PCM into `AudioSourceOutputStreams` and strengthening `CoreAudioTapSource` rebuild cleanup; 6/6 speed-suite sysaudio runs survived output-device swaps with no segfaults.

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
| 8 | Remove legacy ScreenCapture permission helper and retired sysaudio source | ✔ done | `Subcommands/SysAudio.swift`, `Core/Audio/CoreAudioTapSource.swift` |
| 9 | Garbage-collect `sys-HHMMSS.wav` 4 KB rejects from `~/Movies/pi-captures/sessions/20260514-112533-live/audio/` | done locally; watch for regression | session dir |
| 10 | Add a `scripts/reset-tcc.sh` dev helper that runs `tccutil reset ScreenCapture <bundle-id>` + `tccutil reset Microphone <bundle-id>` + `tccutil reset AudioCapture <bundle-id>` whenever the chronicle.app code-signing hash changes | pending | `scripts/reset-tcc.sh` |
| 11 | Pre-allocate `AVAudioPCMBuffer` pool inside `CoreAudioTapSource` IOProc; current code still materialises/converts per callback and is acceptable only as a first productionised source | pending hardening | `Core/Audio/CoreAudioTapSource.swift` |
| 12 | Guard `kAudioHardwarePropertyDefaultOutputDevice` listener against self-induced device-change notifications | ✔ done with cached resolved default-output `AudioObjectID` | `Core/Audio/CoreAudioTapSource.swift` |
| 13 | Device-switch stability hardening (`AudioSourceOutputStreams` + `CoreAudioTapSource`) | ✔ done | `Sources/Chronicle/Core/Audio/AudioSource.swift`, `Sources/Chronicle/Core/Diarize/StreamingDiarizer.swift` |

Live session being captured during the incident lives at:
`~/Movies/pi-captures/sessions/20260514-112533-live/`.

## Robustness layer (audio pipeline)

Three defensive layers prevent live audio capture failures from hanging the daemon:

| Layer | Lives in | Catches |
|---|---|---|
| L1 stable bundle identity | `scripts/make-app.sh` + `Info.plist` | TCC prompts/grants for Microphone and System Audio Recording attach to `chronicle.app`, not a transient bare binary. |
| L2 CoreAudio tap startup validation + idle warning | `Core/Audio/CoreAudioTapSource.swift` | Invalid tap setup fails with System Audio Recording remediation; idle output logs a ~5 s warning, then re-warns every ~30 s, while keeping capture running until audio starts. |
| L3 bounded analyzer finalize (5 s + 2 s) | `Subcommands/Mic.swift` + `Subcommands/SysAudio.swift` | SpeechAnalyzer hung at shutdown after degenerate input. Falls through to `cancelAndFinishNow`. |

Production operator path requires a proper `.app` bundle (built via
`scripts/make-app.sh`) so that codesign binds the Info.plist and macOS
TCC resolves a stable identity. See AGENTS.md.

## What's plugged in vs what's still abstract

`Core/` ships these protocols today; everything below is composition:

| Protocol | Today's impls | Future impls |
|---|---|---|
| `AudioSource` | `MicAudioSource` (AVAudioEngine), `CoreAudioTapSource` (CoreAudio process tap) | `FileAudioSource` (P5 testing); RTSP / Bluetooth (post-PRD) |
| `TranscriptionSink` | `LiveFileSink`, `FinalsAppendSink`, `JSONLTraceSink` | `TagsJSONLSink` (P6) |
| audio sidecar sink (`AudioSidecarSink`) | `AVAudioFileALACSink` + `RollingPCMScratchSink` default; `WAVSidecarSink` and `OpusCAFSink` opt-in | source-native hi-fi sidecar is deferred indefinitely / watchlist only (#79); `ExtAudioFile` ALAC fallback only if `AVAudioFile` regresses |
| `OfflineDiarizing` | `OfflineDiarizer` (FluidAudio VBx) | — |
| (planned) `StreamingDiarizing` | — | `StreamingDiarizer` (FluidAudio Sortformer, P5) |
| `ContentTagger.tagText` / `Summarizer.summarizeText` | cached via `ModelHost.shared` | — |

## How to pick the next thing to do

Default order is the table above. The functional batch in [`plan-functional-trace-merge-diarize-locale`](architecture/plan-functional-trace-merge-diarize-locale.md) (FR-2/FR-7/FR-4/FR-6) is done; next priority is FR-5 live tagging, then verification. After compaction or restart, resume at #26 unless the operator changes priority. If you have a real reason to deviate:

- The protocol-oriented core (ADR-0001) means **any single phase is
  cheap to land** because every other phase composes against the same
  protocols.
- Phases that prerequisite each other are explicit:
  - P8 (merge) now follows completed P3 because trace schema should prove source-aware export before speaker/locale metadata lands.
  - P5 (live diarize) needs `BufferMulticast`; land it after trace/merge so speaker labels flow into a durable source-aware event shape.
  - P4 (locale auto-detect) can run after trace/merge so locale state and switches are debuggable from the same event spine.
  - P6 (live tagging) reads `TranscriptionSink` finals; it composes onto any P3 / P4 / P5 outcome without coupling.
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
| P3 JSONL | #23 | done |
| P4 LocaleResolver | #24 | done |
| P5 streaming diarize | #25 | done |
| P6 live tagging | #26 | open |
| P8 merge | #28 | done |
| P9 verification | #29 | open |
| P10 docs receipts | #30 | open |
| CoreAudioTapSource cleanup | #55 | done |
| Scratch fsync policy | #72 | open |
| Active ALAC CAF tail repair research | #73 | open |
| Sidecar fanout profiling | #74 | done — see [`spikes/2026-05-17-sidecar-fanout-profile.md`](../spikes/2026-05-17-sidecar-fanout-profile.md) |
| Scratch allocation profiling | #75 | done — see [`spikes/2026-05-17-scratch-allocation-profile.md`](../spikes/2026-05-17-scratch-allocation-profile.md) |
| Retire legacy sysaudio source | #76 | done |
| Drain BufferConverter residual frames on stop | #77 | done |
| Source-native hi-fi audio sidecar watchlist | #79 | deferred indefinitely |

Use `TaskRead taskIds=["<id>"]` for full acceptance criteria; use
`TaskRead` with no args to list everything.
