# Technology Steering

## Platform

- Swift 6.2+ / SwiftPM single executable target, macOS 26 Tahoe only.
- Apple Silicon is assumed; on-device Apple frameworks and ANE-backed models are first-class.
- Live capture must run through `/Applications/chronicle.app` when TCC identity matters; `swift build` artifacts are valid for tests/offline subcommands, not for production mic/sysaudio capture.

## Core Frameworks

- `Speech.SpeechAnalyzer` / `SpeechTranscriber` for live and offline transcription.
- `AVFoundation` for mic input, audio conversion, and ALAC/WAV sidecar IO.
- CoreAudio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`, private aggregate device) for system audio.
- FluidAudio Sortformer for streaming speaker diarization.
- WhisperKit audio language detection for locale auto-detect where text-level detection is insufficient.
- FoundationModels, Vision, Translation, NaturalLanguage, and SoundAnalysis power secondary local ML subcommands.

## Runtime Rules

- Do not route live system audio through BlackHole/Multi-Output by default. CoreAudio taps capture the current default output directly.
- Do not make TCC/private preflight the authority for sysaudio health. Runtime nonzero peak and transcript/trace output are the authority.
- Keep live audio sources behind `AudioSource`; keep output side effects behind sink protocols.
- Preserve source boundaries at the analyzer boundary. Do not mix mic and sysaudio buffers into one raw transcriber stream without source labeling before merge.
- Use signed `.app` bundle identity for live TCC workflows; ad-hoc signing is for throwaway CI/debug only.

## Verification

- Swift changes require `swift test` at minimum.
- Live capture changes require overlapping capture + real audio playback/TTS proof: nonzero `sessionPeak`, JSONL trace events, and transcript text in `finals.md`/`live.md`.
- Hot-path refactors must preserve documented parity/acceptance criteria from `docs/` or explicitly update the Kiro spec that supersedes them.

---
_Document durable choices and constraints, not every dependency._
