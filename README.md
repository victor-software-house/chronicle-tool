# chronicle

Tahoe Neural Engine toolkit for the [chronicle](https://github.com/victor-software-house/research-chronicle) project.

Single Swift binary, multiple subcommands, each exercising one Apple-official Tahoe / macOS 26 ML framework on-device. Free, private, ANE-accelerated.

## Subcommands

| Subcommand | Framework | Status |
|---|---|---|
| `transcribe` | `Speech` / `SpeechAnalyzer` + `SpeechTranscriber` (offline preset) | TODO |
| `live` | `Speech` / `SpeechAnalyzer` + `SpeechTranscriber` (`.progressiveTranscription`) | TODO |
| `classify` | `SoundAnalysis` / `SNClassifierBuiltIn` | TODO |
| `tag` | `FoundationModels` (`SystemLanguageModel(useCase: .contentTagging)`) | TODO |
| `summarize` | `FoundationModels` (`SystemLanguageModel`, guided generation) | TODO |
| `translate` | `Translation` framework | TODO |
| `ocr` | `Vision` document recognition + smudge detection | TODO |
| `diarize` | [FluidAudio](https://github.com/FluidInference/FluidAudio) SwiftPM | TODO |

All except `diarize` use first-party Apple frameworks. `diarize` exists because Apple ships no speaker-diarization API.

## Requirements

- macOS 26.0 (Tahoe) or later
- Apple Silicon (M-series)
- Apple Intelligence enabled (required for `tag`, `summarize`)
- Xcode 26 or Swift 6.2+

## Build

```sh
swift build -c release
.build/release/chronicle --help
```

## Why a single binary

Each subcommand is a thin POC that validates one Tahoe framework end-to-end. Composing them is the job of the broader chronicle pipeline. Keeping every framework wrapped here means one place to verify Neural Engine usage and one place to update for SDK changes.

## See also

- `../notes/` — research design + decisions
- `../notes/spikes/2026-05-13-apple-speechanalyzer/` — initial validation
- Sibling research repos cloned under `../`: `apple-speechanalyzer-cli` (argmax demo), `speech-analyzer-dylib`, `swift-scribe`, `fluidaudio`, `samscribe`, `ora`, `meetily`, `meeting-transcriber`.
