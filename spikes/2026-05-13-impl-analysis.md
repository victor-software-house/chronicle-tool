# Reference implementation analysis — Apple speech & friends

Date: 2026-05-13.
Sources reviewed: Apple official `SpeechAnalyzer` documentation + example code,
Argmax `apple-speechanalyzer-cli-example`, FluidInference `swift-scribe`,
FluidInference `FluidAudio` SDK, FluidInference `On-device-SpeechTranscription`
(JuniperPhoton), `Stenographer` (otaviocc), `TokDown` (SCTY-Inc).

## Apple-official patterns

Apple's WWDC25 session 277 sample and the
[`SpeechAnalyzer` reference](https://developer.apple.com/documentation/speech/speechanalyzer)
establish the canonical pipeline:

```swift
import Speech

// 1. Resolve a supported locale.
guard let locale = SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
    // emit "unsupported locale" path; fall back to DictationTranscriber
    return
}

// 2. Pick a preset.
//    .transcription              — offline, accuracy-first.
//    .progressiveTranscription   — live, low-latency, volatile + final results.
let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

// 3. Install assets if needed.
if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()
}

// 4. Pick the best supported PCM format.
let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

// 5. Build an input AsyncStream of AnalyzerInput.
let (input, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)

// 6. Wire the analyzer.
let analyzer = SpeechAnalyzer(modules: [transcriber])

// 7. Consume results concurrently.
Task {
    for try await result in transcriber.results {
        let s = String(result.text.characters)
        // result has `range`, `isFinal`, alternatives, etc.
        print(s, terminator: result.isFinal ? "\n" : "")
    }
}

// 8. Push buffers (or hand the analyzer an AVAudioFile).
let last = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: url))
if let last { try await analyzer.finalizeAndFinish(through: last) }
else        { try analyzer.cancelAndFinishNow() }
```

Key API rules Apple documents:

- `SpeechAnalyzer` decouples input ingestion, result delivery, and session
  control. Each lives on its own task.
- `analyzeSequence(from:)` accepts an `AVAudioFile` and performs format
  conversion automatically. Use this for offline file transcription.
- For live audio, build the `AnalyzerInput.buffer(_:)` stream yourself and call
  `analyzer.start(inputSequence:)` once. Stop with
  `finalizeAndFinishThroughEndOfInput()` when the stream ends, or
  `cancelAndFinishNow()` to drop pending output.
- Results are `AttributedString` with attributed runs that carry timing,
  confidence, and alternatives. Convert with `String(result.text.characters)`
  when you only need plain text.
- `result.isFinal == false` marks volatile results that may be revised.
  Render them in a separate UI element from finalized text.
- `DictationTranscriber` is the older, broader-locale fallback. Use when
  `SpeechTranscriber.supportedLocales` excludes the user's locale.

## Argmax `apple-speechanalyzer-cli-example`

Single-file Swift CLI, 94 LOC. Single commit (`First commit`). Demonstrates
the offline-first flow plus a `--live` flag that switches preset to
`.progressiveTranscription` — but still reads from a file, so the "live"
flag mostly toggles latency vs accuracy, not a streaming source.

Quirks worth knowing:

- Manual `CommandLine.arguments` parsing, no `ArgumentParser`. We use
  ArgumentParser in our tool.
- Aggregates the entire `transcriber.results` stream into one `AttributedString`
  via `reduce(into:)`, then writes plain text. No timings emitted.
- Concatenates results with a trailing `" "` — produces leading/trailing
  whitespace noise. Our POC trims and joins on `result.isFinal`.
- Calls `installedLocales` and only downloads if the locale is missing —
  correct minimal pattern. We replicate this.
- Embeds an `Info.plist` via unsafe linker flags so the binary identifies as
  a real app (needed for entitlements / TCC dialogs to render correctly).
  Our `Package.swift` will need the same pattern when we add live mic input.

Local patch made earlier in this project:
`progressiveLiveTranscription` → `progressiveTranscription` and
`offlineTranscription` → `transcription`. The argmax repo predates the macOS
26 GA preset rename and breaks on shipping SDKs.

## FluidInference `swift-scribe`

Full SwiftUI memo app, 312 LOC just in the transcription module. Useful
patterns:

- Holds `SpeechTranscriber?` and `SpeechAnalyzer?` as actor-isolated state.
- Builds `analyzerFormat` via `SpeechAnalyzer.bestAvailableAudioFormat` after
  the transcriber is created. We follow the same order.
- Owns a long-lived `for try await case let result in transcriber.results`
  loop that accumulates a `finalizedTranscript: AttributedString` and a
  separate volatile string. Same split we want in `live`.
- `ensureModel(transcriber:locale:)` enumerates `installedLocales`,
  `supportedLocales`, `assetInstallationRequest(supporting:)`, and the
  `reserve(locale:)` / `release(reservedLocale:)` reservation API. The
  reservation API is required if you want guarantees the asset stays
  resident across other apps' downloads.
- Calls `analyzer.finalizeAndFinishThroughEndOfInput()` on stop rather
  than `cancelAndFinishNow()` — preserves trailing speech, which is what
  we want for chronicle.

## FluidInference `FluidAudio`

Apache 2.0 / MIT Swift SDK. CoreML models on the ANE. Not an Apple-official
framework — but it ships the only on-device speaker diarizer with a clean
Swift API.

Public surface relevant to chronicle:

```swift
import FluidAudio

// One-time model bundle download into ~/Library/Caches.
let models = try await DiarizerModels.downloadIfNeeded()

let diarizer = DiarizerManager()           // online; alternatives below
diarizer.initialize(models: models)

let converter = AudioConverter()           // any input format → 16kHz mono Float32
let samples = try converter.resampleAudioFile(url)

let result = try diarizer.performCompleteDiarization(samples)
for seg in result.segments {
    print("\(seg.speakerId) \(seg.startTimeSeconds) → \(seg.endTimeSeconds)")
}
```

Diarizer options and their tradeoffs (from FluidAudio's own doc):

| Diarizer | Strength | Max speakers | Best for |
|---|---|---|---|
| `DiarizerManager` (legacy online) | Quiet rooms, whispers | unlimited | older flow, reference |
| `SortformerDiarizer` | Real-world meetings, stable IDs | 4 | Zoom / podcasts |
| `LSEENDDiarizer` | Overlapping speakers, noise | 10 | conferences |
| `OfflineDiarizerManager` (VBx pipeline) | Highest accuracy on a full file | unlimited | post-hoc batch |

For chronicle, the right initial pick is `OfflineDiarizerManager` for batch
re-labeling of saved speech, and `SortformerDiarizer` for the live path.
Both are public API; both run on the Neural Engine.

Also note: FluidAudio ships its own VAD (Silero) and Parakeet ASR. We deliberately
ignore the ASR — Apple's `SpeechTranscriber` is the right STT for English on
Tahoe. Reuse FluidAudio only for diarization (and possibly VAD if the
SoundAnalysis route turns out to be too coarse).

## `On-device-SpeechTranscription`, `Stenographer`, `TokDown`

These are three independent macOS 26 apps confirming Apple's pattern works
end-to-end with no surprises:

- `JuniperPhoton/On-device-SpeechTranscription` — file batch transcription
  with multi-locale support. Confirms the model is shared across apps and
  auto-updates.
- `otaviocc/Stenographer` — drag-and-drop file transcriber that streams
  results as they arrive (uses the same volatile-vs-final split swift-scribe
  uses).
- `SCTY-Inc/tokdown` — menu-bar app that combines `ScreenCaptureKit` system
  audio with `SpeechTranscriber` and writes markdown. Closest in spirit to
  chronicle's intended pipeline. Worth shallow-reading their
  `SystemAudioService.swift` and `TranscriptionService.swift` when we build
  the live mode.

## Decisions for the chronicle tool

- Use Apple-official `SpeechAnalyzer` + `SpeechTranscriber` for STT, mirroring
  swift-scribe's actor isolation but exposing CLI-friendly stdout streaming.
- Use `ArgumentParser` for subcommand dispatch (already wired).
- Use `OfflineDiarizerManager` from FluidAudio for diarization on saved
  speech-only WAVs; later add `SortformerDiarizer` for live.
- Add `Info.plist` linker injection in `Package.swift` when we wire mic input
  and entitlements (needed for live mode).
- Write each subcommand as a small, isolated POC so we validate each Tahoe
  framework independently before composing them.
