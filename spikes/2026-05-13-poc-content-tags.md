# POC-4 + POC-5 — FoundationModels content tagging + summarization

Date: 2026-05-13.
Binaries: `.build/release/chronicle tag` and `.build/release/chronicle summarize`.
Pattern: `SystemLanguageModel(useCase: .contentTagging)` plus
`SystemLanguageModel.default` with `LanguageModelSession.respond(to:generating:)`
guided generation against a `@Generable` Swift struct.

## Goal

Validate that Apple's on-device 3B Foundation Model can replace what we
would otherwise pay OpenAI/Anthropic to do for transcript metadata:

- topic tags + entity extraction + action extraction (the content-tagging
  adapter is purpose-trained for this)
- structured summaries (tl;dr + bullets + decisions + action items) via
  guided generation against a `@Generable` Swift type

…all on-device, $0, private.

## Code

Both `Tag.swift` and `Summarize.swift` are wired:

- `tag` uses `SystemLanguageModel(useCase: .contentTagging)` — Apple's
  topic-tagging adapter, exposed via the same `LanguageModelSession` /
  `respond(to:generating:)` API as the general model. We feed it a
  `ChronicleTagSet` Generable struct with `topics`, `entities`, `actions`.
- `summarize` uses `SystemLanguageModel.default` (the general 3B model)
  with `instructions:` ("be faithful, do not invent facts") and a
  `ChronicleSummary` Generable struct: `tldr`, `bullets`, `decisions`,
  `actionItems`.
- Both surface `SystemLanguageModel.Availability.unavailable(reason:)` cleanly
  with actionable error messages.

`@Generable` macros must be applied at file or type scope — not inside a
function body. We hit `local type cannot have attached extension macro`
once before moving the structs to the file level. Documented here so the
next implementer does not repeat the mistake.

## Runtime check

```sh
.build/release/chronicle tag -i out/speech-only.txt
# [tag] error: Foundation Models unavailable: appleIntelligenceNotEnabled
# [tag] Enable Apple Intelligence in System Settings → Apple Intelligence & Siri.

.build/release/chronicle summarize -i out/speech-only.txt
# [summarize] error: Foundation Models unavailable: appleIntelligenceNotEnabled
```

This machine is **Apple-Intelligence-eligible** (M4 Pro, macOS 26.5 Tahoe)
but the feature is not enabled. Probe verified:

```text
availability: unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.appleIntelligenceNotEnabled)
status: UNAVAILABLE reason=appleIntelligenceNotEnabled
```

## Blockers

- User must enable Apple Intelligence in **System Settings →
  Apple Intelligence & Siri**. This is a one-time toggle plus model
  download (a few GB).
- After enable, re-run both subcommands against
  `~/workspace/victor/research/chronicle/tool/out/speech-only.txt` and
  capture latency + output quality.

## Expected output schemas

Tag:

```json
{
  "elapsedSeconds": 1.2,
  "inputCharacters": 3387,
  "topics": ["speech recognition", "seed determinism", "opportunity testing"],
  "entities": ["David", "Apple", "SpeechAnalyzer"],
  "actions": ["debug", "fix", "analyze"]
}
```

Summarize:

```json
{
  "elapsedSeconds": 3.5,
  "inputCharacters": 3387,
  "tldr": "Discussion about fixing a seed-determinism bug in opportunity test control assignment.",
  "bullets": ["...", "..."],
  "decisions": ["Use the enum name instead of the memory address as the seed input."],
  "actionItems": ["Verify ordering of opportunities is stable across runs."]
}
```

## Decision

- Wire both into chronicle once Apple Intelligence is enabled.
- Treat the on-device 3B model as the **default LLM layer**; reserve paid
  cloud LLMs (Anthropic, OpenAI) for cases the on-device model demonstrably
  fails on. For tagging/summarization this is the *cost-zero* path.
- For future use cases not covered by `.contentTagging` (entity linking,
  classification into custom taxonomies, structured extraction), keep using
  `SystemLanguageModel.default` with a domain-specific `@Generable` struct.

## Reference

- [FoundationModels framework](https://developer.apple.com/documentation/FoundationModels)
- [Updating prompts for new model versions](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions)
- WWDC25 session 286, "Meet the Foundation Models framework"
- WWDC25 session 259, "Code-along: Bring on-device AI to your app using the
  Foundation Models framework"
