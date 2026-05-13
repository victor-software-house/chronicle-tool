# POC-2 — Progressive (live-preset) transcription

Date: 2026-05-13.
Binary: `.build/release/chronicle live`.
Pattern: `SpeechAnalyzer.analyzeSequence(from:)` + `SpeechTranscriber(preset: .progressiveTranscription)`.

## Goal

Validate the `.progressiveTranscription` preset end-to-end: confirm the
volatile-then-final result stream emits as documented, measure latency
deltas vs the offline `.transcription` preset, and characterise the
volatile/final split. Mic input is deferred (needs Info.plist +
NSMicrophoneUsageDescription); file-driven streaming exercises the same
preset over the same audio.

## Run

```sh
.build/release/chronicle live \
  -i ~/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/speech-only.wav \
  -o out/speech-only.live.json \
  --locale en-US
```

## Result

| Metric | Value |
|---|---|
| Audio | `speech-only.wav` (344.43 s) |
| Elapsed | 3.82 s |
| Realtime factor | 90.1 × (vs 103.1 × on `.transcription`) |
| Volatile events | 856 |
| Final events | 40 |
| Cost | $0 (on-device, ANE) |

Sample stdout (TTY-coloured volatile vs final):

```text
volatile   0.00s: Yes
volatile   0.00s: Yes, so
volatile   0.00s: Yes, so basically
volatile   0.00s: Yes, so basically I have been working on
FINAL      0.00s: Yes, so, uh, basically, uh, I have been working on the,
volatile   6.00s: oh, sorry
FINAL      6.00s: Oh, sorry.
```

This is exactly the volatile-then-final pattern Apple documents and that
chronicle's live UI needs. Each volatile event arrives in ~10 ms wall-clock
intervals. Finals come ~hundreds of ms behind the last volatile in the
same range.

## Volatile vs final ratio

```text
volatileEvents / finalEvents = 856 / 40 ≈ 21.4
```

Roughly 21 volatile updates per final segment. For a live UI we should
debounce volatile rendering (e.g. only repaint on every Nth volatile or
every 200 ms wall-clock) to avoid hammering the terminal / TUI.

## Latency vs `.transcription` (offline preset)

| Preset | RTF | Use case |
|---|---:|---|
| `.transcription` | 103.1 × | offline accuracy pass |
| `.progressiveTranscription` | 90.1 × | live UX, low end-to-end latency |

`.progressiveTranscription` is ~13 % slower because it emits intermediate
results; both run on the Neural Engine and both are still ~80-100 × faster
than wall-clock, so neither becomes a bottleneck for 24/7 capture.

## Output schema

```json
{
  "audioDurationSeconds": 344.43,
  "elapsedSeconds": 3.82,
  "realtimeFactor": 90.09,
  "preset": "progressiveTranscription",
  "volatileEvents": 856,
  "finalEvents": 40,
  "events": [
    {
      "wallclockOffsetMs": 57.92,
      "audioRangeStart": 0.0,
      "audioRangeEnd": 28.928,
      "isFinal": false,
      "text": "Yes"
    },
    {
      "wallclockOffsetMs": 80.29,
      "audioRangeStart": 0.0,
      "audioRangeEnd": 105.728,
      "isFinal": false,
      "text": "Yes, so basically, I"
    }
  ]
}
```

The `wallclockOffsetMs` column lets us reconstruct UI repaint cost from
real recordings; chronicle's TUI debouncer can be tuned against it.

## Path to real mic input (deferred)

For a microphone-driven live mode, the same code needs:

1. An `Info.plist` declaring `NSMicrophoneUsageDescription`.
2. Code-signing (or accepting the TCC prompt on every run).
3. Replace `AVAudioFile` + `analyzeSequence(from:)` with an
   `AVAudioEngine` input-node tap that yields buffers into a custom
   `AsyncStream<AnalyzerInput>` (`analyzer.start(inputSequence:)`).
4. Stop via `finalizeAndFinishThroughEndOfInput()` on graceful shutdown.

Reference implementation: the swift-scribe app at
`chr-swift-scribe/Scribe/Audio/Recorder.swift`. The same audio-format
conversion (`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`)
is required to match the transcriber's expected PCM format. We'll wire
this when the chronicle CLI graduates from "spike binary" to "daemon".

## Decision

Adopt `.progressiveTranscription` as the chronicle live STT layer. For
24/7 capture, run `live` against the rolling mic master file (we already
write a fragmented WAV per minute) — no need to wire AVAudioEngine until
we move to a daemon. Tail-style file streaming + the preset's volatile
events already gives us a working live transcript with $0 cost.
