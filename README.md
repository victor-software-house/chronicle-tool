# chronicle

Tahoe Neural Engine toolkit for the [chronicle](https://github.com/victor-software-house/research-chronicle) project.

One Swift 6 binary, multiple subcommands, each exercising one Apple-official Tahoe / macOS 26 ML framework on-device. Free, private, ANE-accelerated. Spike validated end-to-end (see [`spikes/`](spikes/)); production direction set by [PRD-001](docs/prd/PRD-001-resilient-multi-source-daemon.md) and the ADRs under [`docs/adr/`](docs/adr/).

## Subcommands — all working

| Subcommand | Apple framework / dep | Validated time | Cost |
|---|---|---:|---|
| `transcribe` | `Speech.SpeechAnalyzer` + `SpeechTranscriber(.transcription)` | **273 ×** rt on 6870 s WAV (P0 parity: byte-identical) | $0 |
| `live` | `Speech.SpeechAnalyzer` + `SpeechTranscriber(.progressiveTranscription)` (file) | **91 ×** rt, 856 volatile + 40 final events | $0 |
| `mic` | `AVAudioEngine` input tap → `SpeechAnalyzer.start(inputSequence:)` (+ optional `--diarize`, `--locale auto`) | real-time mic stream | $0 |
| `sysaudio` | `CoreAudioTapSource` process tap → `SpeechAnalyzer.start(inputSequence:)` (+ optional `--diarize`, `--locale auto`) | real-time system audio mix smoke-tested with TTS | $0 |
| `classify` | `SoundAnalysis.SNClassifyImageRequest` (built-in classifier v1) | **584 ×** rt | $0 |
| `diarize` | FluidAudio (CoreML, Neural Engine) — only non-Apple dep | **787 ×** rt (post-refactor 872 ×), 5 speakers / 91 segments, byte-identical to spike | $0 |
| `ocr` | `Vision.RecognizeDocumentsRequest` (Tahoe) / `RecognizeTextRequest` | 0.5 – 4 s per 2992×1934 image | $0 |
| `tag` | `FoundationModels.SystemLanguageModel(useCase: .contentTagging)` | 2 – 7 s for 0.3-4 k char transcript (session cached via `ModelHost`) | $0 |
| `summarize` | `FoundationModels.SystemLanguageModel.default` + `@Generable` | 2 – 6 s for 0.3-4 k char transcript (session cached via `ModelHost`) | $0 |
| `translate` | `Translation.TranslationSession` + `NaturalLanguage.NLLanguageRecognizer` | 1 – 22 s | $0 (after one-time language-pack install) |
| `describe` | `Vision` 7-request fan-out + `FoundationModels` `@Generable` narration | 1 – 2.5 s per image | $0 |
| `encode-opus` | `AVFoundation.AVAudioConverter` (Opus) + `AudioFileWritePackets` (CAF) via `OpusCAFSink` | **145 ×** rt on 5 s sine (debug build); P11 verification helper | $0 |
| `encode-alac` | `AVFoundation.AVAudioFile` ALAC-in-CAF via `AVAudioFileALACSink` | **long-reference verified**; P11 parity helper | $0 |
| `scratch-export` | raw PCM scratch manifest + `AVAudioFile`/`AVAudioFileALACSink` | sample-exact unit coverage for Int16/Float32 recovery | $0 |

ML/capture subcommands are validated against real chronicle data captured during
the 2026-05-13 Zoom spike. Helper subcommands (`encode-*`, `scratch-export`) are
covered by focused sidecar/export tests. See the per-POC receipts under
[`spikes/`](spikes/) for the spike-era exact numbers; the P0 modular refactor
preserved byte-identical outputs for `transcribe` and `diarize` against those
receipts.

## Spec, ADRs, and rollout

The project is moving from a 10-subcommand spike (above) to a resilient
multi-source chronicle daemon. The spec set lives under [`docs/`](docs/):

- [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](docs/prd/PRD-001-resilient-multi-source-daemon.md) — the master PRD (FRs, NFRs, rollout plan, verification appendix).
- [`docs/adr/ADR-0001-modular-pipeline-architecture.md`](docs/adr/ADR-0001-modular-pipeline-architecture.md) — protocol-oriented core with subcommands as thin CLI veneers. **Implemented (P0).**
- [`docs/adr/ADR-0002-audio-storage-format.md`](docs/adr/ADR-0002-audio-storage-format.md) — ALAC-in-CAF default with raw-PCM rolling scratch; Opus retained only as opt-in/export after WER regression. **Implemented (P11).**
- [`docs/adr/ADR-0003-locale-resolution-policy.md`](docs/adr/ADR-0003-locale-resolution-policy.md) — candidate-set restriction + 4-knob hysteresis for `--locale auto`. **Implemented (P4).**
- [`docs/adr/ADR-0005-audio-sidecar-reuse-boundary.md`](docs/adr/ADR-0005-audio-sidecar-reuse-boundary.md) — Apple-native sidecar writer + Chronicle-owned rotation/scratch/recovery boundary. **Accepted.**

Current state vs PRD-001 rollout: **P0 (modular refactor), P2a (scratch recovery), P3 (JSONL trace), P4 (locale resolver), P5 (streaming diarization), P7 (sysaudio), P8 (merge), and P11 (ALAC production sidecar) are done. `scratch-export` now automates raw-PCM
scratch recovery; remaining FRs are live tagging (FR-5), repair, and end-to-end verification.**

For a one-screen overview of every phase + current task state, see
[`docs/STATUS.md`](docs/STATUS.md). For agent / contributor operational
guidance (orientation order, hard rules for changes, parity reference
data, commit style), see [`AGENTS.md`](AGENTS.md).

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
- **`.app` bundle required for `mic` / `sysaudio`** — macOS Sequoia/Tahoe
  attributes audio TCC to a stable bundle identity. The bare
  `swift build` binary has `Info.plist=not bound`; build and install the
  proper local app bundle with a stable Apple Development signing identity:

  ```sh
  CHRONICLE_TEAM_ID=<your-team-id> scripts/make-app.sh --install
  ```

  `CHRONICLE_TEAM_ID` is optional when only one Apple Development identity is
  present. The signed app is installed at `/Applications/chronicle.app`; run via
  `/Applications/chronicle.app/Contents/MacOS/chronicle` for live capture.
  Use `scripts/make-app.sh --ad-hoc` only for throwaway CI/debug builds because
  ad-hoc TCC grants do not survive rebuilds.
- **Microphone TCC permission** — grant `chronicle.app` (bundle ID
  `com.victor-software-house.chronicle`) under System Settings → Privacy
  & Security → Microphone.
- **Screen & System Audio Recording TCC permission** — grant
  `chronicle.app` under System Settings → Privacy & Security → Screen
  & System Audio Recording. The private preflight probe can report an
  advisory denial from launcher context; runtime evidence is authoritative:
  nonzero tap peak plus text in `live.md` / `finals.md` means capture works.
  If runtime buffers stay silent while audible audio is playing, check this
  grant, stale signing identity, output routing, or CoreAudio state.
- **Xcode 26 or Swift 6.2+**.

## Menu bar app (ChronicleApp)

The primary interface for live capture is the **ChronicleApp** menu bar
application. It provides two-click access to mic and system audio capture
with optional streaming diarization, live transcript preview, and session
management — all from a persistent menu bar icon.

### Build from Xcode

```sh
cd ChronicleApp
xcodegen generate          # regenerate .xcodeproj from project.yml
open ChronicleApp.xcodeproj
# ⌘R to build and run
```

Or from the command line:

```sh
cd ChronicleApp && xcodegen generate
xcodebuild -project ChronicleApp.xcodeproj -scheme ChronicleApp -configuration Release build
```

The app is signed automatically with Apple Development (team `CXLYTY8DMR`),
bundle ID `com.victor-software-house.chronicle`. No dock icon (`LSUIElement`).

### TCC grants for ChronicleApp

1. Build and run from Xcode (⌘R).
2. System Settings → Privacy & Security → Microphone → grant ChronicleApp.
3. System Settings → Privacy & Security → Screen & System Audio Recording → grant ChronicleApp.
4. TCC grants survive Xcode rebuilds (same team ID + bundle ID).

### Features

- **Status icon**: waveform (idle), record circle (recording), warning triangle (error).
- **Capture controls**: start mic, sysaudio, or both; stop per source.
- **Diarization toggle**: streaming Sortformer speaker labels in transcript.
- **Live transcript preview**: last 50 lines with `[S0]`/`[S1]` speaker prefixes.
- **Session info**: elapsed duration, active sources, speaker count.
- **Open session folder**: reveals output directory in Finder.
- **Launch at login**: via `SMAppService` (persists across reboots).
- **Clean shutdown**: finalizes capture on quit (bounded 5s + 2s timeout).

### CLI remains available

The `chronicle` CLI continues to work for offline subcommands (`transcribe`,
`diarize`, `merge`, etc.) via `swift build`. The CLI's `make-app.sh` path
for live capture is superseded by ChronicleApp but remains functional.

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
.build/release/chronicle mic --locale auto --diarize --seconds 30 -o out/mic.trace.jsonl

# Live mic as a daemon: lossless audio + rolling live snapshot + final-only log + JSONL trace.
.build/release/chronicle mic \
  --locale auto:en-US,pt-BR,es-ES \
  --diarize \
  --live out/live.md \
  --append out/finals.md \
  --save-audio out/audio.wav \
  -o out/trace.jsonl

# Live system-audio capture (everything playing through the current default output device).
/Applications/chronicle.app/Contents/MacOS/chronicle sysaudio \
  --locale auto \
  --diarize \
  --live out/sys-live.md \
  --append out/sys-finals.md \
  --save-audio out/sys-audio.wav

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

# Recover recent audio from raw PCM scratch into WAV.
.build/release/chronicle scratch-export out/audio/scratch/session -o out/recovered.wav

# Or recover into ALAC-in-CAF.
.build/release/chronicle scratch-export out/audio/scratch/session -o out/recovered.caf --format alac
```

## End-to-end pipeline

A five-stage pipeline (classify → transcribe → diarize → tag → summarize)
exists at `spikes/scripts/run-pipeline.sh`. It chains the subcommands and
produces a single output directory per session. Total wall-clock for the
2026-05-13 6870 s Zoom session: **57 s**.

## Live capture daemons (real-time, multi-sidecar)

Both `mic` and `sysaudio` are long-lived daemons that share the same
pipeline shape. They differ only in the `AudioSource` implementation:
`mic` taps `AVAudioEngine.inputNode`, `sysaudio` uses a CoreAudio process
tap (`CATapDescription` + private aggregate device) for the system
output mix.

```text
AudioSource (MicAudioSource | CoreAudioTapSource)
  → BufferConverter (→ analyzerFormat from SpeechAnalyzer.bestAvailableAudioFormat)
  → fan-out via two AsyncStreams:
      ├─ AsyncStream<AnalyzerInput> → SpeechAnalyzer + .progressiveTranscription [ANE]
      │    → volatile / final events → TranscriptionSink fan-out:
      │        ├─ LiveFileSink     → live.md      (atomic rewrite per event, ~150 ms cadence)
      │        ├─ FinalsAppendSink → finals.md    (timestamped append per phrase)
      │        └─ JSONLTraceSink   → trace.jsonl  (source-aware append-only event stream)
      └─ AsyncStream<PCMBufferRef>  → audio sidecar sinks (default: ALAC-in-CAF + raw PCM scratch).
```

`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` is the format
boundary for live capture. Apple documents that `SpeechAnalyzer` does not
transparently upsample, downsample, or convert buffer input because it preserves
sample-accurate `CMTime` values; Chronicle therefore converts source buffers
before yielding `AnalyzerInput`. Current storage records the converted analyzer
PCM (what SpeechAnalyzer heard), not the source-native tap PCM. On current live
smokes this is 16 kHz mono Int16; callers must not hard-code that shape.

Resource cost per daemon: **~0.5–0.8 % CPU, ~30 MB RSS, ALAC sidecar size
varies by source but the 6870 s reference compressed to ~91.3 MB, ~10 KB/s of
text sidecars, ~150 ms volatile latency, 5–30 s final latency.** The model
runs off-process on the ANE; the daemon just does the tap + convert +
fan-out + file writes. On M4 Pro / 48 GB the ANE + RAM headroom supports
~100–200 parallel real-time streams — the actual bottleneck is the audio
device / TCC ceiling. Source-native hi-fi storage is explicitly deferred
indefinitely: it does not serve the transcript-first default and would be much
larger. Keep it as a watchlist item only; if future hi-fi/source-analysis work
becomes real, add a separate source-native sidecar branch before
`BufferConverter` rather than changing the transcription path.

Full receipts (spike-era):
[`spikes/2026-05-13-daemon-live-mic.md`](spikes/2026-05-13-daemon-live-mic.md).
Note: that spike's source-code layout is now historical; the production
shape follows [ADR-0001](docs/adr/ADR-0001-modular-pipeline-architecture.md).

### `sysaudio` capture scope

`CoreAudioTapSource` captures the mix flowing through the macOS **default
audio output device** at the time of capture and follows default-output
switches by rebuilding the tap after the new output stabilizes. It does **not**
require BlackHole 2ch or a Multi-Output Device for normal Chronicle capture.
Those remain useful only for external fallback recorders such as OBS/ffmpeg
loopback. Apps routing audio to other devices (a specific HDMI out, an audio
interface bypass, etc.) may bypass capture. `--include-self-audio` opts
chronicle's own audio back in (default is excluded to prevent feedback loops).
When capture appears silent but the daemon is otherwise healthy, run with
`--verbose` to see state transitions and periodic peak summaries; use
`--debug-tap` only for very noisy per-buffer tap diagnostics.

## Running it under the Pi process tool

For a chronicle-style 24/7 setup, run as a background process:

```sh
# via pi process tool (preferred — captures stdout/stderr, alerts on failure):
process action=start name=chronicle-mic-live \
  command='cd <repo> && exec .build/release/chronicle mic --locale pt-BR --live <vault>/live.md --append <vault>/finals.md --save-audio <vault>/audio.wav -o <vault>/trace.jsonl'

# or raw nohup if you prefer:
nohup .build/release/chronicle mic --locale pt-BR \
  --live  ~/chronicle/live.md \
  --append ~/chronicle/finals.md \
  --save-audio ~/chronicle/audio.wav \
  -o ~/chronicle/trace.jsonl &> ~/chronicle/daemon.log &
```

The daemon handles `SIGTERM` cleanly —
`finalizeAndFinishThroughEndOfInput()` flushes the last in-flight volatile
into a final before closing, so `finals.md` and the JSONL trace stay
consistent.

## Architecture

Single executable target `Chronicle` plus a `ChronicleTests` Swift Testing
target. Subcommands are thin CLI veneers; reusable logic lives in
`Core/<area>/` per [ADR-0001](docs/adr/ADR-0001-modular-pipeline-architecture.md):

```text
Sources/Chronicle/
├── Chronicle.swift                @main + subcommand dispatch
├── Subcommands/                   thin CLI veneers (one per command)
│   ├── Mic.swift                  live mic capture
│   ├── SysAudio.swift             live system-audio capture
│   ├── Live.swift                 progressive-preset STT, file-driven
│   ├── Transcribe.swift           offline STT
│   ├── Diarize.swift              offline speaker diarization
│   ├── Tag.swift / Summarize.swift / Translate.swift
│   ├── Classify.swift             SoundAnalysis built-in classifier
│   ├── OCR.swift                  Vision document / text recognition
│   └── Describe.swift             Vision + FoundationModels narration
└── Core/
    ├── Audio/
    │   ├── AudioSource.swift      protocol: AsyncStreams of AnalyzerInput + PCMBufferRef
    │   ├── MicAudioSource.swift   AVAudioEngine impl
    │   ├── CoreAudioTapSource.swift CoreAudio process tap impl
    │   └── BufferConverter.swift  AVAudioConverter wrapper
    ├── Speech/
    │   └── TranscriptionEngine.swift  SpeechTranscriber + SpeechAnalyzer factory
    ├── Diarize/
    │   ├── Diarizer.swift             DiarizationSegment + OfflineDiarizing protocol
    │   └── OfflineDiarizer.swift      FluidAudio VBx wrapper
    ├── LLM/
    │   ├── ModelHost.swift            cached LanguageModelSession
    │   ├── ContentTagger.swift        tagText(_:limit:)
    │   └── Summarizer.swift           summarizeText(_:bullets:)
    ├── Sinks/
    │   ├── TranscriptionSink.swift    protocol: didReceiveVolatile/Final/finish
    │   ├── LiveFileSink.swift         atomic-rewrite live.md
    │   ├── FinalsAppendSink.swift     timestamped append finals.md
    │   └── JSONLTraceSink.swift       source-aware append-only trace.jsonl
    └── Runtime/
        ├── SignalHandler.swift        SIGINT/SIGTERM one-shot wait
        └── AtomicFile.swift           atomic-write + append-line primitives
```

`Package.swift` embeds `Info.plist` via `-sectcreate` so the OS recognises
the binary as a real app for TCC dialogs (required for Microphone and
System Audio Recording prompts).

Implemented and remaining phases compose here:

- **P3 (FR-2) JSONL trace** — `JSONLTraceSink: TranscriptionSink`.
- **P4 (FR-6) locale auto-detect** — `Core/Speech/LocaleResolver.swift` with live hot-swap.
- **P5 (FR-4) live diarization** — `Core/Audio/BufferMulticast.swift` +
  `Core/Diarize/StreamingDiarizer.swift` consuming `PCMBufferRef`.
- **P6 (FR-5) live tagging** — `Core/Sinks/TagsJSONLSink.swift` calling
  the existing `ContentTagger.tagText` (still pending).

Implemented sidecar pieces:

- **P11 (FR-1 production) ALAC audio sidecar** —
  `Core/Sinks/AVAudioFileALACSink.swift` +
  `Core/Sinks/RollingPCMScratchSink.swift` +
  `Core/Sinks/AudioSidecarCombinators.swift`.
  The default `--audio-format alac` writes rotated ALAC-in-CAF segments and a
  parallel raw-PCM scratch ring.
- **FR-8 scratch recovery helper** — `chronicle scratch-export` reads
  `audio/scratch/<session>/format.json` plus contiguous `.pcm` segments and
  emits WAV or ALAC-in-CAF.

Diarization is the only non-Apple dependency:
[FluidAudio](https://github.com/FluidInference/FluidAudio) — Apple ships no
public diarizer on Tahoe 26.

## Tests

```sh
swift test
```

`Tests/ChronicleTests/` uses Swift Testing (`@Test`). 108 tests across FR-2/FR-4/FR-6 and sidecar suites (JSONL trace, locale resolver, streaming diarizer, latency monitor, sink coverage, plus ALAC/sidecar and CoreAudio suites). More tests land alongside each FR per
PRD-001 file breakdown (`JSONLTraceSinkTests`, `LocaleResolverTests`, `StreamingDiarizerWiringTests`, etc.).

## P11 audio sidecar — ALAC default + scratch recovery

The default live audio sidecar is ALAC-in-CAF, written through Apple's
high-level `AVAudioFile` API. Chronicle feeds it rounded Int16 PCM in the
analyzer format. Opus remains available only as an explicit opt-in/export path
because it failed the long-reference WER gate.

```sh
chronicle mic \
  --save-audio audio/session.caf \
  --audio-format alac \
  --rotate-audio 60 \
  --scratch-ttl 300 \
  --scratch-rotate 30
```

Default outputs:

```text
audio/session-000001.caf       finalized ALAC segment
audio/session-000002.caf       finalized ALAC segment
audio/session-000003.caf       active ALAC segment while running

audio/scratch/session/format.json
audio/scratch/session/000000.pcm
audio/scratch/session/000001.pcm
...
```

Important crash model:

* `--rotate-audio 60` bounds the **active ALAC segment's finalization exposure**
  to roughly one minute.
* It does **not** mean Chronicle expects to lose one minute of audio.
* The parallel scratch tier is raw, headerless PCM. It has no finalization step;
  bytes that reached disk remain usable after `SIGKILL` or a crash.
* If the active CAF segment is unreadable, recover recent audio from
  `audio/scratch/<session>/*.pcm` within the scratch TTL.
* Actual unrecoverable loss should be the final buffer/write that did not reach
  disk, not the whole active ALAC segment.

Scratch recovery:

```sh
# WAV output (inferred from .wav).
chronicle scratch-export audio/scratch/session -o recovered.wav

# ALAC-in-CAF output.
chronicle scratch-export audio/scratch/session -o recovered.caf --format alac
```

`scratch-export` reads `format.json`, validates canonical interleaved scratch
layout, requires contiguous numbered `.pcm` files, trims partial trailing frames,
and writes a standard audio file through AVFoundation.

Verification and decision receipts:

* `AVAudioFile` ALAC probe on the 6870 s Zoom reference:
  `alac`, `s16p`, 16 kHz mono, 91,316,352 bytes, decoded PCM `cmp-ok`.
* Live mic smoke with `--rotate-audio 1` produced two readable ALAC CAF segments
  plus scratch PCM.
* [ADR-0005](docs/adr/ADR-0005-audio-sidecar-reuse-boundary.md) documents why
  Chronicle keeps Apple-native writers plus local rotation/scratch policy rather
  than adopting AudioKit, SFBAudioEngine, AVAssetWriter segmentation, ffmpeg, or
  GStreamer for the live daemon path.

## Historical P11 verification — rejected Opus round-trip WER parity (#50)

Offline test that proved the proposed `OpusCAFSink` default degraded
transcription accuracy beyond the PRD-001 FR-1 tolerance. Kept as a regression
and comparison harness; not the default-format gate anymore.

```sh
swift build -c release
brew install uv          # one-time, for the jiwer script
scripts/verify-opus-parity.sh
```

What it does, by step:

1. **encode** — `chronicle encode-opus` streams the reference WAV through
   `OpusCAFSink @ 24 kbps` and writes `out/parity/mic-master.opus.caf`.
2. **transcribe** — `chronicle transcribe` consumes the CAF artefact via
   `AVAudioFile(forReading:)` (Apple decodes Opus-in-CAF to 48 kHz Float32
   transparently) and writes `out/parity/transcribe-opus.{txt,json}`.
3. **wer** — `scripts/wer.py` (uv-inline jiwer) compares the hypothesis
   transcript against `out/full-session/transcribe.txt` (the WAV baseline)
   and prints a one-line metric plus a JSON receipt. The script exits
   non-zero if WER exceeds `ACCEPT_THRESHOLD` (default `0.01`, i.e. 1 %).

Overridable knobs (env vars):

| Var | Default | Purpose |
|---|---|---|
| `REF_WAV` | `~/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/mic-master.wav` | input reference |
| `REF_TXT` | `out/full-session/transcribe.txt` | baseline transcript |
| `BITRATE` | `24000` | Opus encode bitrate (bits/sec) |
| `OUT_DIR` | `out/parity` | artefact destination |
| `LOCALE` | `en-US` | SpeechAnalyzer locale |
| `ACCEPT_THRESHOLD` | `0.01` | WER pass gate |

This harness is retained to guard the rejected Opus path and to reproduce the
failure if the decision is challenged again. It is no longer a release gate for
the default sidecar.

## See also

- [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](docs/prd/PRD-001-resilient-multi-source-daemon.md) — master spec (FRs, NFRs, rollout, verification).
- [`docs/adr/`](docs/adr/) — architecture decisions (modular pipeline, audio codec, locale policy).
- [`../notes/`](../notes/) — design + decisions for the broader chronicle project.
- [`../notes/research-notes.md`](../notes/research-notes.md) — Tahoe surface map, retention tiers, cost model.
- [`spikes/`](spikes/) — per-POC receipts (impl analysis, offline transcribe, live
  preset, sound classify, vision OCR, content tags, summarise, translate,
  diarize, screenpipe-defer, describe). Source-code layout in those spikes
  predates the P0 modular refactor; treat them as historical evidence.
- Sibling repos under `..`: `apple-speechanalyzer-cli` (argmax demo, retired),
  `swift-scribe`, `fluidaudio`, `samscribe`, `ora`, `meetily`,
  `meeting-transcriber`, `speech-analyzer-dylib`.

## License

MIT.
