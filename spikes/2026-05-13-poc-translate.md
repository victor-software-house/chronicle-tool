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

---

## Update — runtime validated 2026-05-13 (language packs installed)

Operator installed the relevant pairs via System Settings → Language & Region
→ Translation Languages. Re-ran:

**PT-BR → EN (explicit source)**

```text
input  (92 ch): Olá, hoje eu vou explicar como funciona o sistema de transcrição em tempo real no chronicle.
elapsed: 1.05 s
output (86 ch): Hello, today I will explain how the real-time transcription system works in chronicle.
```

**ES → EN (auto-detected via NLLanguageRecognizer)**

```text
[translate] source=es (auto-detected)
input  (95 ch): Hola, hoy voy a explicar cómo funciona el sistema de transcripción en tiempo real en chronicle.
elapsed: 0.87 s
output (93 ch): Hello, today I am going to explain how the real-time transcription system works in chronicle.
```

**EN → PT-BR — full 5-min Zoom transcript**

```text
input:  3387 chars (out/speech-only.txt)
elapsed: 17.33 s
output: 3612 chars (out/speech-only.pt-BR.txt)

Sample (head): "Sim, então, uh, basicamente, uh, eu tenho trabalhado no, oh,
desculpe. Sim, então basicamente na segunda-feira, eu falei com o David
sobre o segundo, a semente aleatória fixa para a atribuição de controle de
teste de oportunidades..."
```

Throughput: ~195 chars/s on the full transcript, ~80-100 chars/s on the
shorter strings (warmup amortises on the longer run). All on-device, $0.

**Decision unchanged:** `translate` is wired as the opportunistic post-pass
for any non-English transcript chunk; runs after `transcribe` and before
`tag`/`summarize` so the downstream LLM always sees English.
