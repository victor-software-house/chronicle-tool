# chronicle

Tahoe Neural Engine toolkit for the [chronicle](https://github.com/victor-software-house/research-chronicle) project.

One Swift 6 binary, multiple subcommands, each exercising one Apple-official Tahoe / macOS 26 ML framework on-device. Free, private, ANE-accelerated. Whole stack validated end-to-end (see `spikes/`).

## Subcommands — fully validated

| Subcommand | Apple framework / dep | Validated time | Cost |
|---|---|---:|---|
| `transcribe` | `Speech.SpeechAnalyzer` + `SpeechTranscriber(.transcription)` | **273 ×** rt on 6870 s WAV | $0 |
| `live` | `Speech.SpeechAnalyzer` + `SpeechTranscriber(.progressiveTranscription)` (file) | **91 ×** rt, 856 volatile + 40 final events | $0 |
| `mic` | `AVAudioEngine` input tap → `SpeechAnalyzer.start(inputSequence:)` | real-time mic stream | $0 |
| `classify` | `SoundAnalysis.SNClassifyImageRequest` (built-in classifier v1) | **584 ×** rt | $0 |
| `diarize` | FluidAudio (CoreML, Neural Engine) — only non-Apple dep | **787 ×** rt, 5 speakers / 91 segments on full session | $0 |
| `ocr` | `Vision.RecognizeDocumentsRequest` (Tahoe) / `RecognizeTextRequest` | 0.5 – 4 s per 2992×1934 image | $0 |
| `tag` | `FoundationModels.SystemLanguageModel(useCase: .contentTagging)` | 5 – 7 s for 3-4 k char transcript | $0 |
| `summarize` | `FoundationModels.SystemLanguageModel.default` + `@Generable` | 4 – 6 s for 3-4 k char transcript | $0 |
| `translate` | `Translation.TranslationSession` + `NaturalLanguage.NLLanguageRecognizer` | 1 – 22 s | $0 (after one-time language-pack install) |
| `describe` | `Vision` 7-request fan-out + `FoundationModels` `@Generable` narration | 1 – 2.5 s per image | $0 |

All ten subcommands run on the Neural Engine, all are validated against real
chronicle data captured during the 2026-05-13 Zoom spike. See the per-POC
receipts under `spikes/` for exact numbers.

## Requirements

- **macOS 26.0 (Tahoe) or later**
- **Apple Silicon (M-series)**
- **Apple Intelligence enabled** — needed for `tag`, `summarize`, and the
  narration step of `describe`. Toggle in System Settings → Apple Intelligence
  & Siri. Siri must be set to one of the supported locales: en-US, en-AU,
  en-GB, fr-CA, fr-FR, es-US, es-ES, es-419, it-IT, pt-PT, pt-BR, vi-VN,
  zh-HK, zh-CN, zh-TW, tr-TR, ko-KR, sv-SE, de-DE, nb-NO, nl-NL, ja-JP,
  da-DK.
- **Translation language packs** — `translate` requires the requested pair
  to be pre-installed via System Settings → Language & Region → Translation
  Languages. The CLI emits a clear remediation message when a pack is
  missing.
- **Microphone TCC permission** — `mic` requires Microphone permission. The
  embedded Info.plist (`NSMicrophoneUsageDescription`) triggers the
  first-run prompt; grant it once via System Settings → Privacy & Security
  → Microphone.
- **Xcode 26 or Swift 6.2+**.

## Install / build

```sh
git clone git@github.com:victor-software-house/chronicle-tool.git
cd chronicle-tool
swift build -c release
.build/release/chronicle --help
```

## Quick start

```sh
# Offline transcribe of a meeting recording.
.build/release/chronicle transcribe \
  -i meeting.wav \
  -o out/meeting \
  --locale en-US

# Live microphone (Ctrl-C to stop, or --seconds N to auto-stop).
.build/release/chronicle mic --locale en-US --seconds 30 -o out/mic.json

# Speech pre-gate over a long session.
.build/release/chronicle classify \
  -i mic-master.wav \
  -o out/mic.classify.json \
  --threshold 0.3 --speech-only

# Speaker diarization.
.build/release/chronicle diarize -i meeting.wav -o out/meeting.diarize.json

# Tag + summarize the transcript.
.build/release/chronicle tag       -i out/meeting.txt -o out/meeting.tag.json
.build/release/chronicle summarize -i out/meeting.txt -o out/meeting.summary.json

# Translate.
.build/release/chronicle translate -t pt-BR -i out/meeting.txt -o out/meeting.pt-BR.txt

# OCR a keyframe (Tahoe document mode with table extraction).
.build/release/chronicle ocr -i frame.png -o out/frame.json

# Describe an arbitrary image in prose.
.build/release/chronicle describe -i photo.jpg -o out/photo.json
```

## End-to-end pipeline

A five-stage pipeline (classify → transcribe → diarize → tag → summarize)
exists at `spikes/scripts/run-pipeline.sh`. It chains the subcommands and
produces a single output directory per session. Total wall-clock for the
2026-05-13 6870 s Zoom session: **57 s**.

## Architecture

Single executable target `Chronicle` under `Sources/Chronicle/`. Each
subcommand lives in its own file:

```
Sources/Chronicle/
├── Chronicle.swift     # @main + subcommand dispatch
├── Transcribe.swift    # offline STT
├── Live.swift          # progressive-preset STT, file-driven
├── Mic.swift           # live mic + AVAudioEngine tap
├── Classify.swift      # SoundAnalysis built-in classifier
├── Diarize.swift       # FluidAudio diarization
├── OCR.swift           # Vision document / text recognition
├── Tag.swift           # FoundationModels content tagging
├── Summarize.swift     # FoundationModels guided summary
├── Translate.swift     # Apple Translation + NLLanguageRecognizer
└── Describe.swift      # Vision multi-request + FoundationModels narration
```

`Package.swift` embeds `Info.plist` via `-sectcreate` so the OS recognises
the binary as a real app for TCC dialogs (required for the Microphone
prompt on `mic`).

Diarization is the only non-Apple dependency:
[FluidAudio](https://github.com/FluidInference/FluidAudio) — Apple ships no
public diarizer on Tahoe 26.

## See also

- `../notes/` — design + decisions for the broader chronicle project.
- `../notes/research-notes.md` — Tahoe surface map, retention tiers, cost model.
- `spikes/` — per-POC receipts (impl analysis, offline transcribe, live
  preset, sound classify, vision OCR, content tags, summarise, translate,
  diarize, screenpipe-defer, describe).
- Sibling repos under `..`: `apple-speechanalyzer-cli` (argmax demo, retired),
  `swift-scribe`, `fluidaudio`, `samscribe`, `ora`, `meetily`,
  `meeting-transcriber`, `speech-analyzer-dylib`.

## License

MIT.
