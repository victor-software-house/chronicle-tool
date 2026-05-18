---
title: "Functional trace, merge, diarization, and locale batch"
prd: "PRD-001-resilient-multi-source-daemon"
date: 2026-05-17
author: "Victor"
status: Draft
---

# Plan: Functional trace, merge, diarization, and locale batch

## Source

* **PRD**: [`../prd/PRD-001-resilient-multi-source-daemon.md`](../prd/PRD-001-resilient-multi-source-daemon.md)
* **Date**: 2026-05-17
* **Author**: Victor

## Architecture Overview

This batch turns the current single-source live commands into a source-aware functional chronicle surface without prematurely building the future menu-bar UI or combined daemon. The batch keeps `chronicle mic` and `chronicle sysaudio` as separate capture processes, then makes their outputs durable, mergeable, speaker-label-ready, and locale-aware.

Execution order is dependency-driven: first create a canonical append-only trace event stream, then build `chronicle merge` on top of that trace, then add live diarization labels into the same event shape, then add locale resolution once the event spine can record locale state and switches. This avoids losing source awareness at the `SpeechAnalyzer` boundary because mic and system audio remain one-source-per-transcriber and merge later by timestamped trace events.

The implementation should prefer small shared Core helpers over a full `LivePipeline` refactor. `Mic.swift` and `SysAudio.swift` can continue as thin orchestration veneers, but duplicated result-handling code should shrink into reusable event/sink helpers as each phase lands.

## Current Checkpoint — 2026-05-17

Phases 1 (FR-2), 2 (FR-7), and 3 (FR-4) are implemented. The batch is not complete.

| Batch item | Task | FR                         | Status | Commit                                                                | Current evidence                                                                                                                                                                                                                                                                  |
| ---------- | ---- | -------------------------- | ------ | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1          | #23  | FR-2 JSONL trace           | Done   | `36375a5 feat: add source-aware JSONL trace`                          | `swift test`, `swift build -c release`, help checks, `git diff --check`, `specdocs_validate`, file-driven live smoke with a 13-event valid `trace.jsonl`.                                                                                                                         |
| 2          | #28  | FR-7 merge                 | Done   | `a4078ce feat: add chronicle merge for source-aware trace and finals` | 10 new `MergeTests` plus full `swift test` (56 tests) green, `swift build -c release` green, `chronicle merge --help`, synthetic JSONL+finals.md smoke, end-to-end smoke with two `chronicle live -o` runs over `say` fixtures merged into one chronological log.                 |
| 3          | #25  | FR-4 streaming diarization | Done   | this commit                                                           | New `BufferMulticast` (6 tests), `DiarizationTimelineLookup` (7 tests), `JSONLTraceSink.didReceiveResult(speakerId:)` propagation test (1), `swift test` 70/70 green, `swift build -c release` green, `chronicle mic --help` / `chronicle sysaudio --help` both show `--diarize`. |
| 4          | #24  | FR-6 locale resolver       | Next   | —                                                                     | Not started. Must emit locale state/switches into trace; restart path can be staged if risky.                                                                                                                                                                                     |

FR-2 changed the shared live result surface: `TranscriptionSink.didReceiveResult(_:isFinal:wallclockOffsetMs:wallclock:audioRange:speakerId:)` now carries optional analyzer timing metadata and an optional speaker label. `JSONLTraceSink` uses both; `FinalsAppendSink` overrides `didReceiveResult` to prefix finals with `[Sx]` when a `speakerId` is present; other sinks fall through to the default protocol forwarder. Future FR-6 work should use this hook instead of adding parallel result loops.

FR-2 also hardened shared append semantics in `AtomicFile.appendLine`: Darwin uses `O_APPEND`, `flock(LOCK_EX)`, EINTR retry, partial-write looping, and `write == 0` failure. That affects `JSONLTraceSink` and existing line append sinks. Merge assumes each complete line is one event, and tolerates at most one torn trailing line per JSONL input.

FR-7 added `Sources/Chronicle/Subcommands/Merge.swift` with helper types `MergedRecord`, `MergeOutcome`, `MergeService`, `MergeInputFormat`, `MergeOutputFormat`, `FinalsMarkdownReader`, and `MergeRenderer`. Default output is a plain log (`[wallclock] [source] (speaker, locale) text`); `--format markdown` produces a markdown table. Stable sort key is `(wallclock, sourcePath, eventId)`; `--source-alias <path>=<name>` overrides source labels for finals.md fallback or for renamed JSONL files; `--include-volatile` is opt-in. Concurrent-writer JSONL files (`chronicle mic -o trace.jsonl` and `chronicle sysaudio -o trace.jsonl` sharing one path) merge into one chronological output because the trace itself is already source-tagged per event.

FR-4 added `Sources/Chronicle/Core/Audio/BufferMulticast.swift` (generic `BufferMulticast<Element>` with per-subscriber `.bufferingNewest` queues so a slow diarizer drops stale audio rather than blocking the source), `Sources/Chronicle/Core/Audio/PCMFloatConverter.swift` (testable PCM-to-16-kHz-mono-Float conversion with Int16 / Float32 fast paths and an `AVAudioConverter` slow path), and `Sources/Chronicle/Core/Diarize/StreamingDiarizer.swift` (the `StreamingDiarizing` protocol, the pure `DiarizationTimelineLookup` value type, the `StreamingDiarizerBackend` protocol with a production `SortformerBackend` wrapping FluidAudio's `SortformerDiarizer`, and the `SortformerStreamingDiarizer` actor that throttles `process()` every ~1 s). `Mic.swift` and `SysAudio.swift` accept `--diarize`: when set, they wrap `pcmBuffers` in a `BufferMulticast<PCMBufferRef>` so the sidecar and the diarizer each get an independent stream, query `diarizer.speakerId(forRange:)` on each result, and pass the speaker label through `TranscriptionSink.didReceiveResult`. `JSONLTraceSink` records the field; `FinalsAppendSink` prefixes finals with `[Sx]`. Speaker IDs are best-effort across a streaming session (Sortformer's own state updater).

Live smoke receipts (2026-05-17, ElevenLabs Sarah US-female + George UK-male fixture, ~62 s of speech routed through speakers): `chronicle sysaudio --diarize` produced 11 finals with 6 `[S0]` (Sarah) + 5 `[S1]` (George) finals, 2 speakers in the live lookup, 109/177 lookup hits; `chronicle mic --diarize` produced 13 finals with consistent `[S0]` Sarah / `[S1]` George labels, 2 speakers, 140/217 lookup hits; `chronicle merge trace.mic.jsonl trace.sys.jsonl` interleaved both runs chronologically with `[source] (speaker, locale) text` lines. The end-to-end smoke uncovered a latent `AVAudioConverter` callback bug: in production the converter returned `nil` for every back-to-back Int16 16 kHz mono buffer, so the diarizer received only one sample and never produced segments. The initial FR-4 unit tests only covered the `DiarizationTimelineLookup` value type and never exercised the conversion path. The fix extracts `PCMFloatConverter` with dedicated Int16/Float32 fast paths, plus a 7-test `PCMFloatConverterTests` suite and a 7-test `StreamingDiarizerWiringTests` suite that stubs the backend so ingest counting, process throttling, lookup merging, and finalize behaviour are all exercised without loading CoreML.

## Resume After Compaction

Start with #24. Do not claim the 1–4 batch is finished until #24 is also implemented, validated, committed, pushed, and task-marked complete.

Minimum restart sequence:

1. `set_session_context(status="working", tabTopic="Locale Resolver", workLabel="fr6 locale")`.
2. `TaskWrite` #24 → `in_progress`.
3. Read this file, PRD-001 FR-6, `docs/adr/ADR-0003-locale-resolution-policy.md`, `docs/STATUS.md`, `Sources/Chronicle/Subcommands/Mic.swift`, `Sources/Chronicle/Subcommands/SysAudio.swift`, and the existing `TranscriptionEngine` locale wiring.
4. Add `Sources/Chronicle/Core/Speech/LocaleResolver.swift` implementing ADR-0003 candidate-set restriction + 4-knob hysteresis (`--locale-min-finals`, `--locale-confidence`, `--locale-cooldown-sec`, `--locale-min-chars`).
5. Wire `--locale auto[:set|*]` into mic/sysaudio; on switch, emit a `control` trace event and restart the transcriber.
6. Unit tests cover candidate restriction, hysteresis, cooldown, single-loanword suppression, and `control`-event emission.
7. Validate `swift test`, `swift build -c release`, `git diff --check`, `specdocs_validate`, `chronicle mic --help`, `chronicle sysaudio --help`.
8. Commit/push, then mark #24 complete.

## Components

### TraceEvent schema and JSONLTraceSink

**Purpose**: Provide crash-resistant, source-aware event persistence for live transcription.

**Key Details**:

* Add `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift`.
* Add a stable `TraceEvent` model carrying at least: schema version, event id, `source`, source kind, stream id, wallclock timestamp, monotonic offset ms, event kind, text, `isFinal`, locale, optional `speakerId`, optional audio segment reference, and future channel/export policy fields.
* Use `AtomicFile.appendJSONLine` or equivalent newline-delimited append helper.
* Flush every event first; batching can follow only after crash tests prove bounded loss.
* Wire both `chronicle mic -o trace.jsonl` and `chronicle sysaudio -o trace.jsonl`.
* Preserve existing `live.md` and `finals.md` behaviour.
* Add tests for valid JSONL, malformed trailing-line recovery, source fields, event ordering, and final/volatile events.

**ADR Reference**: PRD D2 already chooses JSONL append-only; no new ADR unless trace schema compatibility becomes disputed.

### Source-aware merge

**Purpose**: Produce one chronological transcript from multiple source traces or finals files without merging raw audio buffers.

**Key Details**:

* Add `Sources/Chronicle/Subcommands/Merge.swift` and register it in `Chronicle.swift`.
* Prefer `trace.jsonl` input because it carries source and future speaker/locale metadata.
* Keep `finals.md` input as fallback for older runs.
* Stable-sort events by wallclock timestamp, then source path, then event id.
* Default output: markdown table with timestamp, source, speaker, locale, and text.
* Preserve source labels (`mic`, `sysaudio`, custom alias) and speaker labels if present.
* Defer unified JSONL output to an explicit later flag (`--format jsonl`) unless needed during implementation.

**ADR Reference**: None — pure subcommand over accepted trace format.

### BufferMulticast and StreamingDiarizer

**Purpose**: Add live speaker labels while preserving source boundaries.

**Key Details**:

* Add `Sources/Chronicle/Core/Audio/BufferMulticast.swift` only if existing `AudioSourceOutputStreams` cannot support analyzer + sidecar + diarizer consumers safely.
* Add `Sources/Chronicle/Core/Diarize/StreamingDiarizer.swift` behind a small protocol that yields time-ranged speaker hypotheses.
* Keep one diarizer per source command; do not diarize a raw mixed mic+sys stream by default.
* Attach `speakerId` to final trace events by aligning transcript timing with diarizer time ranges.
* Prefix finals with `[S<N>]` only when speaker confidence/timing alignment is good enough; otherwise leave speaker empty and keep raw event debuggable.
* Add unit tests for multicast fan-out, slow consumer handling, finish/drain semantics, and speaker alignment on canned time ranges.
* Add one live or file-backed smoke after unit coverage.

**ADR Reference**: ADR-0001 D4 already chooses in-process fan-out. New ADR only if implementation needs bounded queues/backpressure semantics that constrain future consumers.

### LocaleResolver

**Purpose**: Add constrained locale auto-detect without random out-of-set flips.

**Key Details**:

* Add `Sources/Chronicle/Core/Speech/LocaleResolver.swift` per ADR-0003.
* Implement grammar: pinned locale, `auto`, `auto:<list>`, `auto:*`.
* Apply candidate-set restriction and four hysteresis knobs: confidence, consecutive finals, cooldown, min chars.
* Run detector on final text only.
* Emit locale state into trace events so merge/debug can explain language switches.
* If live transcriber restart proves risky, land resolver and event logging first, then implement restart behind focused tests and a live smoke.
* Keep pin mode as disable switch.

**ADR Reference**: [ADR-0003](../adr/ADR-0003-locale-resolution-policy.md) owns policy.

### Shared live result handling

**Purpose**: Keep `Mic.swift` and `SysAudio.swift` thin while adding trace, merge, diarize, and locale hooks.

**Key Details**:

* Extract duplicate result-loop pieces only when needed by FR-2.
* Candidate helper: `Core/Speech/LiveTranscriptionSession.swift` or `Core/Sinks/TranscriptEventFanout.swift`.
* Helper should fan out each result to live file, finals file, trace sink, locale resolver, and optional diarizer state without hiding source identity.
* Avoid a large all-at-once `LivePipeline` rewrite unless duplication starts blocking tests.

**ADR Reference**: ADR-0001 supports this direction; no new ADR for modest helper extraction.

## Implementation Order

| Phase | Component                               | Dependencies                                                              | Estimated Scope | Status            |
| ----- | --------------------------------------- | ------------------------------------------------------------------------- | --------------- | ----------------- |
| 1     | TraceEvent schema + `JSONLTraceSink`    | Existing `AtomicFile`, `TranscriptionSink`, `Mic.swift`, `SysAudio.swift` | M               | Done in `36375a5` |
| 2     | `chronicle merge` over JSONL/finals     | Phase 1 trace schema                                                      | M               | Done in `a4078ce` |
| 3     | `BufferMulticast` + `StreamingDiarizer` | Phase 1 trace fields, Phase 2 merge can inspect output                    | L               | Done              |
| 4     | `LocaleResolver` + locale trace events  | Phase 1 trace fields; ADR-0003                                            | L               | Next              |
| 5     | Batch smoke + docs receipts             | Phases 1-4                                                                | M               | Pending           |

## Risks and Mitigations

| Risk                                                         | Likelihood | Impact | Mitigation                                                                                                         |
| ------------------------------------------------------------ | ---------- | ------ | ------------------------------------------------------------------------------------------------------------------ |
| Trace schema churn breaks merge or downstream tools          | Medium     | Medium | Version trace events from first implementation; keep fields additive; add parser tests for unknown fields.         |
| JSONL writes become hot-path latency source                  | Low        | Medium | Start with per-event flush for correctness; measure; batch only after crash-loss tests prove bounds.               |
| Source awareness lost by early raw-buffer merge              | Medium     | High   | Keep one source per transcriber; merge only trace/finals; document `AnalyzerInput` has no source metadata.         |
| Diarizer backpressures analyzer/sidecar consumers            | Medium     | High   | Use separate task/consumer; unit-test slow consumer path; drop or lag diarizer rather than analyzer.               |
| Speaker alignment wrong under volatile/final timing drift    | Medium     | Medium | Store raw timestamps/ranges in trace; leave `speakerId` nil when confidence/range overlap insufficient.            |
| Locale switch requires analyzer restart and may drop buffers | Medium     | Medium | Implement resolver separately; test restart path; record locale-switch control events; keep pin mode default safe. |
| Merge output overfits markdown and blocks machine consumers  | Low        | Medium | Use JSONL trace as canonical input; keep markdown default; defer `--format jsonl` as additive flag.                |

## Open Questions

* Resolved for FR-2: `TraceEvent` is one global event schema with `eventKind`; future event families should add fields and/or `eventKind` cases rather than replacing the envelope.
* Resolved for next FR-7 pass: `chronicle merge` emits markdown first; `--format jsonl` remains additive future work unless implementation evidence shows immediate machine-consumer need.
* What exact timing axis should diarizer alignment use: analyzer buffer offsets, wallclock offsets, or both? FR-2 now stores both fractional wallclock and monotonic offset plus optional analyzer `audioRange`; FR-4 must decide which axis owns speaker alignment.
* Should live locale switch restart the `SpeechAnalyzer` immediately, or first record candidate/switch events while keeping current transcriber pinned?
* What default source aliases should merge infer from paths: `mic`, `sysaudio`, or caller-provided `--source <name>`? Resolved for FR-7: merge infers source from `TraceEvent.source` for JSONL inputs, and from filename tokens (`mic`, `sys`, `sysaudio`, `live`) for `finals.md` fallback; either can be overridden by `--source-alias <path>=<name>`.

## ADR Index

Decisions surfaced during this plan:

| ADR                                                          | Title                                   | Status                                                                     |
| ------------------------------------------------------------ | --------------------------------------- | -------------------------------------------------------------------------- |
| [ADR-0001](../adr/ADR-0001-modular-pipeline-architecture.md) | Modular pipeline architecture           | Existing                                                                   |
| [ADR-0003](../adr/ADR-0003-locale-resolution-policy.md)      | Locale resolution policy                | Existing                                                                   |
| Pending                                                      | Trace event schema compatibility policy | Watch; create only if schema/envelope choice becomes contested             |
| Pending                                                      | Multicast backpressure/drop policy      | Watch; create only if bounded queue/drop semantics affect future consumers |
