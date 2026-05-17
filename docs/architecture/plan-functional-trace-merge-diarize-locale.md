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

| Phase | Component                               | Dependencies                                                              | Estimated Scope |
| ----- | --------------------------------------- | ------------------------------------------------------------------------- | --------------- |
| 1     | TraceEvent schema + `JSONLTraceSink`    | Existing `AtomicFile`, `TranscriptionSink`, `Mic.swift`, `SysAudio.swift` | M               |
| 2     | `chronicle merge` over JSONL/finals     | Phase 1 trace schema                                                      | M               |
| 3     | `BufferMulticast` + `StreamingDiarizer` | Phase 1 trace fields, Phase 2 merge can inspect output                    | L               |
| 4     | `LocaleResolver` + locale trace events  | Phase 1 trace fields; ADR-0003                                            | L               |
| 5     | Batch smoke + docs receipts             | Phases 1-4                                                                | M               |

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

* Should `TraceEvent` use one global event schema for volatile/final/control/tag events, or separate Codable structs with an envelope?
* Should `chronicle merge` support `--format jsonl` in first pass, or markdown only with trace input?
* What exact timing axis should diarizer alignment use: analyzer buffer offsets, wallclock offsets, or both?
* Should live locale switch restart the `SpeechAnalyzer` immediately, or first record candidate/switch events while keeping current transcriber pinned?
* What default source aliases should merge infer from paths: `mic`, `sysaudio`, or caller-provided `--source <name>`?

## ADR Index

Decisions surfaced during this plan:

| ADR                                                          | Title                                   | Status                                                                     |
| ------------------------------------------------------------ | --------------------------------------- | -------------------------------------------------------------------------- |
| [ADR-0001](../adr/ADR-0001-modular-pipeline-architecture.md) | Modular pipeline architecture           | Existing                                                                   |
| [ADR-0003](../adr/ADR-0003-locale-resolution-policy.md)      | Locale resolution policy                | Existing                                                                   |
| Pending                                                      | Trace event schema compatibility policy | Watch; create only if schema/envelope choice becomes contested             |
| Pending                                                      | Multicast backpressure/drop policy      | Watch; create only if bounded queue/drop semantics affect future consumers |
