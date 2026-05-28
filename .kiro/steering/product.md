# Product Overview

Chronicle is a local-first macOS Tahoe audio and ML toolkit for capturing, transcribing, diarizing, tagging, summarizing, and recovering personal chronicle sessions. It serves the operator running long-lived capture on a personal Mac and downstream review tools that need durable transcript/audio evidence.

## Core Capabilities

- **On-device live capture**: microphone and system-audio subcommands feed Apple's `SpeechAnalyzer` without cloud calls.
- **Crash-resistant sidecars**: transcript traces, finals, live snapshots, ALAC CAF segments, and raw PCM scratch preserve recoverable evidence.
- **Source-aware transcript pipeline**: mic and sysaudio remain separate capture processes; JSONL trace and `chronicle merge` combine them by timestamp while preserving source, locale, and speaker metadata.
- **On-device enrichment**: FluidAudio streaming diarization and Apple FoundationModels/NaturalLanguage integrations add speaker, language, tagging, summarization, translation, OCR, and image description workflows.

## Target Use Cases

- Leave live mic/sysaudio capture running during meetings, calls, or work sessions without losing everything on crash or restart.
- Reconstruct sessions from sidecars after failure, including raw PCM scratch when the active container is damaged.
- Produce reviewable transcripts with source labels, timestamps, speaker labels, and optional tags/summaries.

## Value Proposition

Chronicle favors private, local, Apple-native capture and ML over cloud services. The durable product invariant is: **runtime evidence beats assumptions**. For live capture, success is demonstrated by real PCM and transcript sidecars, not by preflight checks alone.

---
_Focus on patterns and purpose, not exhaustive feature lists_
