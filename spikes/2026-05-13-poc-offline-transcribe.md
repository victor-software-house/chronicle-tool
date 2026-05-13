# POC-1 — Offline transcription via Apple `SpeechAnalyzer`

Date: 2026-05-13.
Binary: `.build/release/chronicle transcribe`.
Pattern: `SpeechAnalyzer.analyzeSequence(from: AVAudioFile)` + `SpeechTranscriber(preset: .transcription)`.

## Goal

Match or beat Argmax CLI's earlier offline run on `speech-only.wav`, and add
per-segment timings + a structured JSON output the argmax demo throws away.

## Run

```sh
.build/release/chronicle transcribe \
  -i ~/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/speech-only.wav \
  -o out/speech-only \
  --locale en-US
```

## Result

| Metric | Value |
|---|---|
| Audio | `speech-only.wav` (silero-extracted speech segments) |
| Audio duration | 344.43 s |
| Elapsed | 3.34 s |
| Realtime factor | 103.1 × |
| Segment count | 49 |
| Output | `out/speech-only.{txt,json}` |
| Cost | $0 (on-device, ANE) |

First segment, end-to-end including JSON encoding, finalize, model load (already
cached from previous validation):

```json
{
  "endSeconds": 6.6,
  "isFinal": true,
  "startSeconds": 0,
  "text": "Yeah, so, uh, basically, uh, I have been working on the, oh, sorry."
}
```

Plain-text head matches the actual Zoom content of the 2026-05-13 session
(opportunity test control assignment, seed-determinism debugging). No
hallucinations on silent boundaries, no `(rauschen)` artifacts.

## Comparison

| Path | Speed | Timings | Cost | Notes |
|---|---|---|---|---|
| Argmax CLI (`apple-speechanalyzer-cli`) | ~75 × rt (earlier run) | dropped | $0 | naive `reduce(into:)` concat |
| **This POC** | **103 × rt** | **per-segment start/end** | **$0** | actor collector + JSON doc |
| whisper.cpp small.en (cpp) | ~3 × rt on M4 Pro | per-segment | $0 | CPU/GPU, not ANE |
| ElevenLabs Scribe v2 (cloud) | 5-10 × rt | per-word | $0.40/h | best accuracy on overlap |

Speed delta over Argmax likely comes from emitting results to an actor-isolated
collector while analysis runs, avoiding the `AttributedString.reduce(into:)`
concat that the demo CLI performed inline.

## Apple framework receipts

- `SpeechTranscriber.supportedLocale(equivalentTo:)` → `en_US` (resolved from
  `en-US`).
- `SpeechTranscriber.installedLocales` → already contained `en_US` from the
  earlier validation run; no `AssetInventory` download triggered.
- `SpeechAnalyzer.analyzeSequence(from:)` accepted the WAV directly — no
  manual format conversion needed.
- `SpeechAnalyzer.finalizeAndFinish(through:)` flushed pending results before
  `transcriber.results` closed; the `consumeTask` reached completion without
  a timeout.

## Output schema

```json
{
  "inputPath": "...",
  "locale": "en_US",
  "preset": "transcription",
  "audioDurationSeconds": 344.43,
  "elapsedSeconds": 3.34,
  "realtimeFactor": 103.09,
  "segmentCount": 49,
  "segments": [
    { "text": "...", "startSeconds": 0.0, "endSeconds": 6.6, "isFinal": true }
  ],
  "plainText": "..."
}
```

This is the shape every chronicle subcommand will accept downstream (diarizer
will merge `startSeconds`/`endSeconds` with speaker labels; summarizer will
consume `plainText` or a chunked version of `segments`).

## Decision

Use Apple `SpeechAnalyzer` + `.transcription` preset as the **default offline
STT layer** for chronicle. whisper.cpp drops to fallback for locales
`SpeechTranscriber` does not support; Scribe stays as a paid second pass for
high-value segments only.
