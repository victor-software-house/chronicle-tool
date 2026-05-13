# POC-8 — Speaker diarization via FluidAudio

Date: 2026-05-13.
Binary: `.build/release/chronicle diarize`.
Pattern: `FluidAudio.DiarizerManager.performCompleteDiarization(samples)` on
16 kHz mono Float32 produced by `AudioConverter.resampleAudioFile(url)`.

## Goal

Validate that a free, on-device, ANE-accelerated diarizer can answer "who
spoke when" against the chronicle Zoom session. Apple ships no diarization
API on macOS 26; FluidAudio is the closest thing to a vendor-quality
substitute.

## Run

```sh
.build/release/chronicle diarize \
  -i ~/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/speech-only.wav \
  -o out/speech-only.diarize.json
```

## Result

| Metric | Value |
|---|---|
| Input | `speech-only.wav` (silero-VAD extracted speech) |
| Audio duration | 344.43 s |
| Elapsed | 2.99 s |
| Realtime factor | 115.4 × |
| Speakers detected | 4 |
| Segment count | 50 |
| Cost | $0 (CoreML / ANE) |

Speaker distribution:

| Speaker | Segments | Talking time |
|---|---:|---:|
| 1 | 42 | 300.3 s |
| 3 | 6 | 14.6 s |
| 2 | 1 | 6.9 s |
| 4 | 1 | 4.3 s |

Speaker 1 = main presenter (us, debugging the seed-determinism bug). Speakers
2/3/4 cluster around the other Zoom call participants.

## Caveats

- Input is silero-VAD-stripped audio. `startSeconds` / `endSeconds` refer to
  the **stripped timeline**, not the original 6870 s session master. Mapping
  back to the original master requires the silero segment table (already
  saved at `…/vad/vad-segments.txt`).
- `DiarizerManager` is FluidAudio's *legacy online* diarizer. The result
  looks plausible but their own docs flag it as "most computationally heavy
  online diarizer" and "struggles with background conversations / overlap".
  For batch chronicle re-labeling we should switch to
  `OfflineDiarizerManager` (VBx pipeline) for higher accuracy.
- For live diarization (POC TBD), `SortformerDiarizer` is the recommended
  choice: up to 4 speakers, stable identities, 480 ms updates on the ANE.

## Output schema

```json
{
  "inputPath": "...",
  "audioDurationSeconds": 344.43,
  "elapsedSeconds": 2.99,
  "realtimeFactor": 115.35,
  "speakerCount": 4,
  "segmentCount": 50,
  "segments": [
    { "speakerId": "1", "startSeconds": 0.15, "endSeconds": 6.34 }
  ]
}
```

Downstream merge with `transcribe`'s output is trivial: both share
`startSeconds` / `endSeconds`. A small `pi-jq`/`jq` script can interleave
the transcript and the diarization.

## Decision

- Use FluidAudio as the **on-device diarization layer** for chronicle. No
  Apple-official alternative exists.
- For batch passes, swap `DiarizerManager` → `OfflineDiarizerManager` once
  we wire a `--mode offline` flag.
- For live, use `SortformerDiarizer` paired with `SpeechAnalyzer`'s
  `.progressiveTranscription` results stream.
- Models live in user caches; first run downloads them (~minutes once,
  ~ms thereafter).
