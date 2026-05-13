# POC-3 — Sound classification pre-gate via Apple `SoundAnalysis`

Date: 2026-05-13.
Binary: `.build/release/chronicle classify`.
Pattern: `SNAudioFileAnalyzer` + `SNClassifySoundRequest(classifierIdentifier: .version1)`.

## Goal

Use Apple's built-in trained sound classifier as a cheap, on-device pre-gate
that decides "this audio actually contains speech, run STT" vs "it's silence
or non-speech, skip". Compare its speech detection against the silero VAD
pass we already ran on the same session.

## Run

```sh
# 1) classify the already-VAD-stripped speech segment.
.build/release/chronicle classify \
  -i ~/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/speech-only.wav \
  -o out/speech-only.classify.json \
  --threshold 0.3

# 2) classify the full 6870 s mic master, speech-only mode.
.build/release/chronicle classify \
  -i ~/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/mic-master.wav \
  -o out/master.classify.json \
  --threshold 0.3 \
  --speech-only
```

## Result

| Input | Duration | Elapsed | RTF | Windows | Speech seconds | Speech ratio |
|---|---:|---:|---:|---:|---:|---:|
| `speech-only.wav` | 344.43 s | 0.60 s | 573 × | 228 | 681 s (overlap) | 197.7%¹ |
| `mic-master.wav` | 6869.87 s | 12.03 s | 571 × | 324 | 972 s | 14.1% |

¹ `SNClassifierVersion1` emits overlapping 1.5 s windows every ~0.5 s. The
"speech seconds" metric sums label durations and intentionally overcounts
overlap. For `speech-only.wav` every window is `speech`, so the 197.7% just
confirms 100% speech across the whole stripped file.

## SoundAnalysis vs silero VAD

| Metric | silero VAD | Apple SoundAnalysis |
|---|---|---|
| Speech detected | 344 s (5.0%) | 972 s (14.1%) |
| Cost | $0 (CPU) | $0 (Neural Engine) |
| Throughput on full session | ~3 min (CPU) | 12 s (ANE, 571 ×) |
| Label vocabulary | speech vs not | ~300 trained classes |
| False positives | very low (strict 0.5 threshold) | higher (0.3 threshold, broader "speech" definition) |
| Pre-gate use | strict | permissive |

Apple SoundAnalysis is **way faster** (571 × vs 3 × on this hardware) and
sees ~3 × more speech because the classifier counts low-volume background
voice / occasional speech-like sound that silero rejects.

## Decision

For chronicle, **wire SoundAnalysis as the always-on cheap pre-gate**:

1. Continuous mic capture → 1 min rolling chunks.
2. Run `classify --speech-only` on each chunk; takes ~ms.
3. Only chunks with non-trivial `speechSeconds` proceed to
   `transcribe`/`live` and `diarize`.
4. Reserve silero VAD as a stricter secondary filter for "should we upload
   this to Scribe for a premium pass" decisions, where cost matters.

This collapses the previous Python-based silero step from a multi-minute
post-pass into a ~10 s ANE pass per hour of audio, and unblocks running the
gate inline with capture instead of as a separate batch job.

## Other useful labels exposed

`SNClassifierVersion1` also recognises: `music`, `speech_synthesizer`,
`telephone_bell_ringing`, `alarm_clock`, `keyboard_typing`, `mouse_click`,
`door`, `traffic`, `applause`, `laughter`, `cough`, `sigh`, `whistling`,
`television`, `radio`, `dog_bark`, etc. — useful for chronicle's "what
kind of moment was this" metadata layer later.
