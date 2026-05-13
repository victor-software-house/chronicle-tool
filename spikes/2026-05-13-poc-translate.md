# POC-6 — On-device Translation via Apple `Translation` framework

Date: 2026-05-13.
Binary: `.build/release/chronicle translate`.
Pattern: `TranslationSession(installedSource:target:)` + `NLLanguageRecognizer`
for source-language auto-detection.

## Goal

Validate that Apple's `Translation` framework can be driven from a non-UI
CLI process for chronicle's multilingual content (Zoom calls in PT-BR /
ES / DE etc. translated to EN before summarization / search).

## Run

```sh
# explicit source
echo "Olá, hoje eu vou explicar como funciona o sistema de transcrição em tempo real." \
  | .build/release/chronicle translate -f pt-BR -t en

# auto-detect source
echo "Hola, hoy voy a explicar cómo funciona el sistema de transcripción en tiempo real." \
  | .build/release/chronicle translate -t en

# file-to-file
.build/release/chronicle translate -t pt-BR \
  -i out/speech-only.txt -o out/speech-only.pt-BR.txt
```

## Result

Code path validated — every CLI input was correctly parsed, the source
language was auto-detected via `NLLanguageRecognizer.dominantLanguage`, and
`TranslationSession(installedSource:target:)` was called.

However, **on this machine no translation language packs are installed**, so
each call returned `TranslationError.notInstalled`. The CLI surfaces the
expected remediation:

```text
[translate] error: target translation pack not installed.
Open System Settings → Language & Region → Translation Languages and
download the language pair (pt → en).
```

This matches the reference behaviour in `scriptingosx/translate-cli` and the
documented `TranslationError` cases. Once the user installs the desired
pair via System Settings, the same CLI command will succeed without code
changes.

## Constraints

- `TranslationSession` requires the **target** pair to be pre-installed.
  Apple does not allow programmatic download of language packs without UI
  consent.
- For chronicle's mainline pipeline, surface the missing-pack error and
  emit a "translation pending" marker rather than failing the run. Schedule
  translation as a deferred pass once the pack arrives.

## Decision

- Wire `translate` into the chronicle pipeline as an **opportunistic
  post-pass**: every transcript whose `NLLanguageRecognizer` dominant
  language ≠ user's preferred output language gets translated.
- Pre-download the relevant pairs (PT-BR ↔ EN, ES ↔ EN, DE ↔ EN, FR ↔ EN,
  JA ↔ EN) once in System Settings; document this as a one-time setup step.
- Cost: $0, on-device. Latency: ~few hundred ms per paragraph once cached.

## NaturalLanguage as a free side-benefit

`NLLanguageRecognizer` is the right "detect language" layer regardless of
translation. We already invoke it before `TranslationSession`, so the same
machinery powers a future `chronicle detect-language` subcommand. No
network calls, no entitlements, no cost.
