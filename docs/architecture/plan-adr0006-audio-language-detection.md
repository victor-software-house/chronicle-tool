---
title: "Implementation plan: ADR-0006 audio-level language detection"
plan: plan-adr0006-audio-language-detection
status: Ready
date: 2026-05-18
adr: "ADR-0006-audio-level-language-detection"
prd: "PRD-001-resilient-multi-source-daemon"
---

# Plan: ADR-0006 audio-level language detection

## Summary

Replace the broken text-based locale detection in FR-6 with WhisperKit
audio-level `detectLanguage()`. The ADR-0003 candidate-set policy,
hysteresis, and CLI grammar are preserved. The detection signal source
changes from NLLanguageRecognizer on transcription text to WhisperKit
on raw audio mel-spectrograms.

## Phases

### Phase 1: Add WhisperKit dependency + AudioLanguageDetector

**Goal:** WhisperKit `base` model loads and detects language from a
`[Float]` audio buffer, filtered to a candidate set.

**Files:**

| File | Action | Purpose |
|---|---|---|
| `Package.swift` | modify | Add WhisperKit dependency |
| `Core/Speech/AudioLanguageDetector.swift` | new | Wraps WhisperKit: load model, detect, filter candidates |
| `Tests/ChronicleTests/Speech/AudioLanguageDetectorTests.swift` | new | Unit test: mock audio → correct detection |

**Acceptance:**
- `swift build` succeeds with WhisperKit dependency
- `AudioLanguageDetector.detect(audioSamples:candidates:)` returns
  correct language + confidence for EN and PT test buffers
- Model loads in <5s (cached), detection in <500ms

**Details:**

`AudioLanguageDetector` is a standalone actor:

```swift
public actor AudioLanguageDetector {
  private var kit: WhisperKit?

  /// Load the WhisperKit base model. Call once at startup.
  public func load() async throws

  /// Detect language from raw 16kHz mono Float samples.
  /// Returns (language, confidence) filtered to candidates.
  /// Candidates default to Locale.preferredLanguages base codes.
  public func detect(
    audioSamples: [Float],
    candidates: Set<String>? = nil
  ) async throws -> (language: String, confidence: Double)
}
```

Default candidates when nil:
```swift
Set(Locale.preferredLanguages.compactMap {
  Locale(identifier: $0).language.languageCode?.identifier
})
```

### Phase 2: Wire into LocaleResolver + capture pipeline

**Goal:** `--locale auto` uses audio-level detection on startup and
periodically. SpeechTranscriber starts at the detected locale.

**Files:**

| File | Action | Purpose |
|---|---|---|
| `Core/Speech/LocaleResolver.swift` | modify | Add `considerAudio(language:confidence:)` method |
| `Core/Speech/LocaleResolverWiring.swift` | modify | Add audio detection integration helpers |
| `Subcommands/Mic.swift` | modify | Wire audio detector: startup probe + periodic |
| `Subcommands/SysAudio.swift` | modify | Wire audio detector: startup probe + periodic |

**Acceptance:**
- `chronicle mic --locale auto` detects language from first ~3s of
  audio and starts transcriber at the correct locale
- Portuguese speech with `--locale auto` produces coherent PT text
  (not gibberish English)
- English speech with `--locale auto` stays on English
- `--locale pt-BR` (pin mode) still works, no detection runs

**Details:**

Startup probe flow in Mic/SysAudio:

```
1. Start audio capture → buffer first ~3s into a [Float] ring
2. After 3s: audioDetector.detect(audioSamples:candidates:)
3. If detected language ≠ initial locale:
   a. hot-swap via setModules() to detected locale
   b. log "[source.locale] audio-detected=XX, switching from YY"
4. Start normal transcription result consumption
```

Periodic re-detection (every 30s):

```
1. Collect latest ~3s of audio from the pcmBuffers stream
2. audioDetector.detect(audioSamples:candidates:)
3. Feed result into localeResolver.considerAudio(language:confidence:)
4. Hysteresis gates apply (consecutive count, cooldown, confidence floor)
5. If switch → hot-swap via setModules()
```

The pcmBuffers stream already exists (used by diarizer + sidecar).
Add one more subscriber via BufferMulticast for the audio detector's
rolling window.

### Phase 3: Remove NLLanguageDetector text-based path

**Goal:** Clean up the dead code path.

**Files:**

| File | Action | Purpose |
|---|---|---|
| `Core/Speech/LocaleResolver.swift` | modify | Remove `consider(final:)` text-based method, remove `NLLanguageDetector` |
| `Core/Speech/LocaleResolverWiring.swift` | modify | Remove text-based detection call from result loop |
| `Subcommands/Mic.swift` | modify | Remove `localeResolver.consider(final:)` call |
| `Subcommands/SysAudio.swift` | modify | Remove `localeResolver.consider(final:)` call |
| `Tests/ChronicleTests/Speech/LocaleResolverTests.swift` | modify | Remove text-based tests, add audio-based tests |

**Acceptance:**
- No references to `NLLanguageDetector` or `consider(final:)` remain
  in production code
- `LocaleLanguageDetector` protocol removed or simplified
- All tests pass
- `--locale auto` still works end-to-end

### Phase 4: Live smoke + commit

**Goal:** Validate end-to-end with real speech.

**Smoke tests:**

1. `chronicle mic --locale auto` → speak Portuguese → verify
   transcription is coherent PT (not gibberish EN)
2. `chronicle mic --locale auto` → speak English → verify stays EN
3. `chronicle mic --locale auto` → speak English then switch to
   Portuguese mid-session → verify locale switches within ~30s
4. `chronicle sysaudio --locale auto` → play EN video → verify EN;
   play PT video → verify switches to PT
5. Device switch (speakers → AirPods) mid-capture → no crash

**Commit plan:**
- P1: `feat(locale): add WhisperKit audio language detector`
- P2: `feat(locale): wire audio detection into mic and sysaudio`
- P3: `refactor(locale): remove text-based NLLanguageDetector path`
- P4: `docs: update STATUS.md and PRD with audio detection receipts`

## Risks

| Risk | Mitigation |
|---|---|
| WhisperKit model download on first run (~150 MB) | Pre-download in `AudioLanguageDetector.load()` with progress log; cached after first use |
| ANE contention between WhisperKit and SpeechTranscriber | Detection runs ~250ms every 30s = <1% duty cycle; negligible |
| WhisperKit dependency size increase | Only `base` model; detection-only usage; no transcription models needed |
| Package.swift resolution conflicts | WhisperKit is a clean SPM package with no overlapping deps |

## Dependencies

- WhisperKit >= 0.16.0 (SPM, Apache 2.0 license)
- Existing: `Core/Speech/LocaleResolver`, `Core/Audio/BufferMulticast`,
  `Core/Speech/LocaleResolverWiring` (hot-swap via `setModules()`)
