---
title: "Audio-level language detection via WhisperKit"
adr: ADR-0006
status: Proposed
date: 2026-05-18
prd: "PRD-001-resilient-multi-source-daemon"
decision: "Use WhisperKit detectLanguage() on raw audio for locale identification; keep SpeechTranscriber for transcription"
---

# ADR-0006: Audio-level language detection via WhisperKit

## Status

Proposed — supersedes the detection mechanism in
[ADR-0003](ADR-0003-locale-resolution-policy.md) while preserving its
candidate-set restriction and hysteresis policy.

## Date

2026-05-18

## Requirement Source

- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md`
- **Decision Point**: §5 FR-6 (locale auto-detect via `--locale auto`).
  ADR-0003 defined the policy (candidate sets, hysteresis, CLI grammar).
  This ADR replaces the *detection mechanism* because the ADR-0003
  mechanism (NLLanguageRecognizer on transcription text) is fundamentally
  broken when the initial locale does not match the spoken language.

## Context

### The chicken-and-egg failure

ADR-0003 specified that locale detection would run `NLLanguageRecognizer`
on finalized transcription text. The assumption was that even if the
wrong locale produced imperfect text, enough real-language signal would
leak through for `NLLanguageRecognizer` to identify the true language.

This assumption is **wrong**. When the initial locale does not match the
spoken language, Apple's `SpeechTranscriber` produces complete gibberish
— not slightly degraded text with recognizable words, but phonetically
hallucinated English words with no Portuguese (or any other target
language) signal:

```
Input:  operator speaking Brazilian Portuguese
Locale: en-US (initial default)
Output: "Uh, do you call me side as you're bored, the passage into
         the mice, 2 Louis, Desha, Alpera, son, my scara, transporta,
         pasa, Jelus, to que para transporta, cardia."
```

`NLLanguageRecognizer` cannot detect Portuguese from this text because
there is no Portuguese in it — the transcriber hallucinated English
phonemes. The hysteresis never fires, and the daemon is stuck on the
wrong locale for the entire session.

This was confirmed in live testing on 2026-05-18: `chronicle mic
--diarize --locale auto` produced unusable output when the operator
spoke Portuguese. Switching to `--locale pt-BR` (pinned) immediately
produced correct transcription. The auto-detect feature as shipped in
FR-6 commits `7e26106`–`605a076` is **non-functional** for the primary
use case (bilingual operator starting a session in a non-default
language).

### Why text-based detection cannot work

The fundamental constraint is that `SpeechTranscriber` commits to a
single locale and produces output in that locale's phonetic model.
Wrong-locale transcription doesn't degrade gracefully — it
hallucinates. This is not a quality tuning problem; it's an
architectural mismatch:

1. You need correct transcription to detect the language from text.
2. You need the correct language to produce correct transcription.
3. There is no graceful middle ground where "slightly wrong" text
   still contains enough target-language signal.

This chicken-and-egg is inherent to any single-locale speech-to-text
system. The Vocai blog ("WhisperKit vs Apple SpeechAnalyzer", 2026-04)
confirms: "Mid-sentence code-switching is not a first-class feature.
SpeechAnalyzer appears to commit to a single language per recording."

### What does work: audio-level detection

WhisperKit (argmaxinc/WhisperKit) implements audio-level language
detection via the Whisper model's encoder-decoder architecture:

1. Audio is processed into a mel-spectrogram (no text involved).
2. The mel-spectrogram is fed through the audio encoder.
3. A `LanguageLogitsFilter` constrains the decoder to language tokens.
4. The decoder predicts the most likely language token directly from
   the audio embeddings.

This works on ~1–5 seconds of audio, requires no transcription, and
supports 99 languages. It operates on the audio signal itself, not on
text, so it is immune to the chicken-and-egg failure.

## Decision Drivers

- **ADR-0003's detection mechanism is non-functional.** The shipped
  FR-6 auto-detect does not work when the operator starts speaking in
  a language other than the initial locale. This is the primary use
  case it was designed for.
- **Audio-level detection is proven technology.** Whisper's language
  detection is well-established (OpenAI Whisper, 2022; WhisperKit
  CoreML port, 2024+). WhisperKit runs on Apple Silicon ANE with
  CoreML, same as the rest of chronicle's ML stack.
- **SpeechTranscriber remains the best transcriber.** Apple's on-device
  model is faster, lower-overhead, and better-integrated than WhisperKit
  for actual transcription. The goal is to use the right tool for each
  job: WhisperKit for detection, SpeechTranscriber for transcription.
- **ADR-0003 policy is sound.** The candidate-set restriction, 4-knob
  hysteresis, CLI grammar (`--locale auto[:list|*]`), and safety
  philosophy are all correct. Only the detection mechanism (run
  NLLanguageRecognizer on transcription text) needs replacement.
- **Minimal new dependency.** WhisperKit is a Swift package with
  CoreML models. It runs on-device, no network required. The `tiny`
  model (~75 MB) is sufficient for language detection.

## Considered Options

### Option 1: WhisperKit audio-level detection + SpeechTranscriber transcription

Add WhisperKit as a dependency. On startup (or periodically), run
`WhisperKit.detectLanguage(audioArray:)` on a short audio buffer
(~3–5 seconds). Use the detected language to select (or confirm) the
`SpeechTranscriber` locale. Continue using SpeechTranscriber for all
transcription.

Two sub-modes:

**A. Startup probe only.** Detect language from the first ~5s of audio.
Set the locale. Never re-detect. Simple, low-overhead, handles the
"operator speaks their language from the start" case.

**B. Periodic re-detection.** Run `detectLanguage()` every N seconds
(e.g. 30s) on a rolling audio window. Apply ADR-0003 hysteresis before
switching. Handles mid-session language switches (e.g. operator takes a
call in a different language).

- Good, because it solves the chicken-and-egg problem completely — no
  transcription text is needed for detection.
- Good, because SpeechTranscriber remains the transcription engine —
  no quality or performance regression for the transcription path.
- Good, because WhisperKit's `tiny` model is small (~75 MB CoreML)
  and loads fast.
- Good, because the ADR-0003 candidate-set restriction still applies:
  WhisperKit's detected language is filtered through the candidate set
  before any switch is applied.
- Good, because sub-mode A (startup only) is trivially simple to
  implement and covers the most common failure case.
- Bad, because WhisperKit is a new dependency (Swift package, ~75 MB
  model download on first use).
- Bad, because running two ML models simultaneously (WhisperKit
  encoder for detection + SpeechTranscriber for transcription) uses
  more memory and ANE time than text-based detection.

### Option 2: Parallel SpeechTranscriber probe at startup

On startup with `--locale auto`, run N `SpeechTranscriber` instances
(one per candidate locale) on the first ~5s of audio. Score each
candidate's output with `NLLanguageRecognizer`. The locale whose
transcription text is identified as its own language with highest
confidence wins.

- Good, because no new dependency — only Apple frameworks.
- Good, because it solves the startup detection case.
- Bad, because running N `SpeechTranscriber` instances simultaneously
  is expensive (each loads a separate model, each consumes ANE time).
  For a 5-locale candidate set, this is 5× the startup cost.
- Bad, because it still relies on text-based scoring — the wrong
  locale may produce text that NLLanguageRecognizer misidentifies
  (e.g. phonetically plausible gibberish in a related language).
- Bad, because it cannot re-detect mid-session without stopping and
  restarting the probe (expensive).
- Bad, because `SpeechTranscriber` model installation for all
  candidates must happen upfront.

### Option 3: Replace SpeechTranscriber with WhisperKit entirely

Use WhisperKit for both language detection and transcription. WhisperKit
natively handles multilingual audio and code-switching.

- Good, because one model handles everything — no coordination needed.
- Good, because WhisperKit supports code-switching natively (Whisper
  was trained on multilingual data).
- Good, because 99 languages supported.
- Bad, because WhisperKit transcription is **slower** than
  SpeechTranscriber on Apple Silicon (Vocai blog: "SpeechAnalyzer is
  roughly 55% faster than Whisper on a 34-minute test file").
- Bad, because WhisperKit does not integrate with the OS
  (SpeechTranscriber shares models with Notes, Voice Memos, etc.).
- Bad, because WhisperKit requires shipping or downloading model
  weights (~75 MB for `tiny`, ~1.5 GB for `large-v3`).
- Bad, because the existing SpeechTranscriber-based pipeline would
  need significant rework.
- Considered for future evaluation if Apple's model proves limiting.

### Option 4: Keep text-based detection, fix with heuristics

Attempt to detect language from the garbage transcription text using
heuristics: character frequency analysis, phoneme pattern matching,
word-frequency scoring against known dictionaries.

- Good, because no new dependency.
- Bad, because the garbage text has no reliable signal. The English
  phoneme hallucinations don't contain target-language patterns — the
  transcriber actively maps foreign phonemes to English words.
- Bad, because any heuristic sophisticated enough to work on this
  garbage would essentially be reimplementing audio-level detection
  with worse tools.
- Rejected as fundamentally unsound.

## Decision

Chosen option: **Option 1 — WhisperKit audio-level detection +
SpeechTranscriber transcription**, sub-mode B (periodic re-detection)
with sub-mode A (startup probe) as the minimum viable implementation.

Rationale:

1. It is the only option that solves the chicken-and-egg problem
   without regressing transcription quality or performance.
2. The WhisperKit dependency is bounded (detection only, `tiny` model,
   ~75 MB) and runs on the same CoreML/ANE stack chronicle already
   uses.
3. ADR-0003's policy layer (candidate sets, hysteresis, CLI grammar)
   remains intact — only the signal source changes from
   "NLLanguageRecognizer on text" to "WhisperKit on audio."
4. Sub-mode A is a minimal implementation that covers the primary
   failure case (wrong initial locale). Sub-mode B extends it to
   mid-session switches without fundamental changes.

### Experimental validation (2026-05-18)

A standalone WhisperKit probe was built and run against the ElevenLabs
voice fixtures generated for the FR-4 speed test suite:

| Fixture | Model | Detected | Confidence | Time |
|---|---|---|---|---|
| sarah_en.wav (23s US female) | tiny | en | -0.002 | 262 ms |
| sarah_pt.wav (21s PT female) | tiny | pt | -0.031 | 228 ms |
| george_pt.wav (21s PT male) | tiny | pt | -0.002 | 238 ms |
| pt_1s.wav (1s Portuguese) | tiny | pt | -0.072 | 238 ms |
| pt_3s.wav (3s Portuguese) | base | pt | -0.005 | 265 ms |
| charlie_en.wav (22s AU male) | tiny | en | -0.002 | 19 ms |

All three models (tiny ~75 MB, base ~150 MB, small ~500 MB) achieved
100% accuracy on the test set. `base` had the best multilingual
confidence calibration (-0.005 for Portuguese vs tiny's -0.031).
`small` was 2× slower with no accuracy gain. **Recommendation: `base`
model for production.**

Confidence values are negative log-likelihoods: -0.005 ≈ 99.5% sure.

Critically: even a **1-second clip** of Portuguese was correctly
identified — the chicken-and-egg problem from ADR-0003 is completely
eliminated since no transcription text is involved.

### Default candidate set: system preferred languages

`Locale.preferredLanguages` returns the operator's configured system
languages (e.g. `["en-BR", "pt-BR"]`). Extracting base language codes
gives the candidate set automatically — no hardcoded `[en-US, pt-BR]`:

```swift
let candidates = Set(
  Locale.preferredLanguages.compactMap {
    Locale(identifier: $0).language.languageCode?.identifier
  }
)
// On this machine: {"en", "pt"}
```

WhisperKit returns probabilities for all 99 languages. Chronicle
filters to the candidate set and picks the highest:

```swift
let (_, probs) = try await kit.detectLanguage(audioArray: samples)
let best = probs
  .filter { candidates.contains($0.key) }
  .max(by: { $0.value < $1.value })
```

### Implementation sketch

```
Startup:
  1. Start audio capture (mic or sysaudio) → buffer audio
  2. After ~3s of audio, run WhisperKit.detectLanguage(audioArray:)
  3. Filter result through candidate set (system languages or CLI override)
  4. If detected locale ≠ initial locale → hot-swap via setModules()
  5. Begin transcription with the detected locale

Periodic (sub-mode B):
  6. Every ~30s, run detectLanguage() on the latest ~3s audio window
  7. Apply hysteresis (consecutive detections, confidence floor, cooldown)
  8. If switch triggered → hot-swap via setModules()
```

The existing `LocaleResolver` state machine is adapted. The
`LocaleLanguageDetector` protocol gets a new implementation
(`WhisperKitAudioDetector`) that wraps `WhisperKit.detectLanguage()`
with candidate filtering. The CLI grammar does not change.

### What stays from ADR-0003

- All four modes: pin, auto-default, auto-list, auto-any.
- Candidate-set restriction via `--locale auto:<list>`.
- 4-knob hysteresis: confidence floor, consecutive threshold,
  cooldown, minimum evidence.
- `~/.config/chronicle/locales.json` safe-set config file.
- `--locale <bcp47>` as the off switch.

### What changes from ADR-0003

| ADR-0003 (text-based) | ADR-0006 (audio-based) |
|---|---|
| NLLanguageRecognizer on finalized text | WhisperKit detectLanguage() on raw audio |
| Runs after each final segment | Runs on startup + periodically on ~3s audio window |
| Fails when initial locale is wrong (chicken-and-egg) | Works regardless of initial locale (1s sufficient) |
| No new dependencies | Adds WhisperKit Swift package (~150 MB base model) |
| ~0 additional compute | ~250 ms per detection call (mel + encoder + decoder) |
| Hardcoded default safe set `[en-US, pt-BR]` | System preferred languages via `Locale.preferredLanguages` |
| `LocaleLanguageDetector` protocol: `NLLanguageDetector` | `LocaleLanguageDetector` protocol: `WhisperKitAudioDetector` |

## Consequences

### Positive

- The `--locale auto` feature actually works for bilingual operators.
- Language detection is decoupled from transcription quality — wrong
  initial locale is self-correcting within ~5s.
- No regression to transcription speed or quality — SpeechTranscriber
  remains the transcriber.
- The existing hysteresis and candidate-set policy prevents WhisperKit
  from suggesting unsupported or unwanted locales.

### Negative

- New dependency: WhisperKit Swift package. Must be added to
  `Package.swift`. Model downloads ~75 MB on first use.
- Two ML models loaded simultaneously: WhisperKit tiny (for
  detection) + SpeechTranscriber (for transcription). Memory overhead
  estimated ~150–200 MB additional for the tiny model.
- Detection adds ~100–300 ms of ANE time per probe. At 30s intervals
  this is negligible (~0.5% duty cycle).
- WhisperKit model updates are not managed by Apple's AssetInventory
  — chronicle must handle model download/caching.

### Neutral

- The `NLLanguageDetector` implementation of `LocaleLanguageDetector`
  can be retained as a fallback or removed. It still works for the
  mid-session text-scoring case where the current locale IS correct
  and we're checking if a switch is needed — but the audio detector
  is strictly superior.
- The `--locale-min-chars` hysteresis knob may need reinterpretation
  for audio-level detection (min-seconds or min-detections instead
  of min-characters). The concept (minimum evidence before switch)
  remains the same.

## Related

- **Supersedes**: [ADR-0003](ADR-0003-locale-resolution-policy.md)
  detection mechanism (candidate-set policy and hysteresis retained).
- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md` — FR-6.
- **ADRs**: [ADR-0001](ADR-0001-modular-pipeline-architecture.md) —
  `WhisperKitAudioDetector` conforms to the existing
  `LocaleLanguageDetector` protocol in `Core/Speech/`.
- **External**: [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  — `detectLanguage(audioPath:)` and `detectLanguage(audioArray:)`.
- **Research**: Vocai blog "WhisperKit vs Apple SpeechAnalyzer" (2026-04)
  — confirms SpeechAnalyzer single-locale commitment and WhisperKit's
  multilingual advantage.
- **Implementation**: To be tracked as a new task superseding the
  current FR-6 text-based detection.
