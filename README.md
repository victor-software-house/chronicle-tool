# chronicle

Tahoe Neural Engine toolkit for the [chronicle](https://github.com/victor-software-house/research-chronicle) project.

One Swift 6 binary, multiple subcommands, each exercising one Apple-official Tahoe / macOS 26 ML framework on-device. Free, private, ANE-accelerated. Spike validated end-to-end (see [`spikes/`](spikes/)); production direction set by [PRD-001](docs/prd/PRD-001-resilient-multi-source-daemon.md) and three ADRs.

## Subcommands — all working

| Subcommand | Apple framework / dep | Validated time | Cost |
|---|---|---:|---|
| `transcribe` | `Speech.SpeechAnalyzer` + `SpeechTranscriber(.transcription)` | **273 ×** rt on 6870 s WAV (P0 parity: byte-identical) | $0 |
| `live` | `Speech.SpeechAnalyzer` + `SpeechTranscriber(.progressiveTranscription)` (file) | **91 ×** rt, 856 volatile + 40 final events | $0 |
| `mic` | `AVAudioEngine` input tap → `SpeechAnalyzer.start(inputSequence:)` | real-time mic stream | $0 |
| `sysaudio` | `ScreenCaptureKit.SCStream` (audio-only) → `SpeechAnalyzer.start(inputSequence:)` | real-time system audio mix | $0 |
| `classify` | `SoundAnalysis.SNClassifyImageRequest` (built-in classifier v1) | **584 ×** rt | $0 |
| `diarize` | FluidAudio (CoreML, Neural Engine) — only non-Apple dep | **787 ×** rt (post-refactor 872 ×), 5 speakers / 91 segments, byte-identical to spike | $0 |
| `ocr` | `Vision.RecognizeDocumentsRequest` (Tahoe) / `RecognizeTextRequest` | 0.5 – 4 s per 2992×1934 image | $0 |
| `tag` | `FoundationModels.SystemLanguageModel(useCase: .contentTagging)` | 2 – 7 s for 0.3-4 k char transcript (session cached via `ModelHost`) | $0 |
| `summarize` | `FoundationModels.SystemLanguageModel.default` + `@Generable` | 2 – 6 s for 0.3-4 k char transcript (session cached via `ModelHost`) | $0 |
| `translate` | `Translation.TranslationSession` + `NaturalLanguage.NLLanguageRecognizer` | 1 – 22 s | $0 (after one-time language-pack install) |
| `describe` | `Vision` 7-request fan-out + `FoundationModels` `@Generable` narration | 1 – 2.5 s per image | $0 |
| `encode-opus` | `AVFoundation.AVAudioConverter` (Opus) + `AudioFileWritePackets` (CAF) via `OpusCAFSink` | **145 ×** rt on 5 s sine (debug build); P11 verification helper | $0 |

All twelve subcommands run on the Neural Engine, all are validated against
real chronicle data captured during the 2026-05-13 Zoom spike. See the
per-POC receipts under [`spikes/`](spikes/) for the spike-era exact numbers; the
P0 modular refactor preserved byte-identical outputs for `transcribe`
and `diarize` against those receipts.

## Spec, ADRs, and rollout

The project is moving from a 10-subcommand spike (above) to a resilient
multi-source chronicle daemon. The spec set lives under [`docs/`](docs/):

- [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](docs/prd/PRD-001-resilient-multi-source-daemon.md) — the master PRD (FRs, NFRs, rollout plan, verification appendix).
- [`docs/adr/ADR-0001-modular-pipeline-architecture.md`](docs/adr/ADR-0001-modular-pipeline-architecture.md) — protocol-oriented core with subcommands as thin CLI veneers. **Implemented (P0).**
- [`docs/adr/ADR-0002-audio-storage-format.md`](docs/adr/ADR-0002-audio-storage-format.md) — Opus 24 kbps / Ogg as default audio codec + raw-PCM rolling scratch + ALAC export. **Pending (P11).**
- [`docs/adr/ADR-0003-locale-resolution-policy.md`](docs/adr/ADR-0003-locale-resolution-policy.md) — candidate-set restriction + 4-knob hysteresis for `--locale auto`. **Pending (P4).**

Current state vs PRD-001 rollout: **P0 (modular refactor) done; P7
(sysaudio) done. Next: P11 (Opus production sink) + parity test against the
WAV baseline.**

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
  `swift build` binary has `Info.plist=not bound` and SCStream silently
  delivers garbage placeholder buffers. Build the proper bundle:

  ```sh
  scripts/make-app.sh
  ```

  Then run via `.build/release/chronicle.app/Contents/MacOS/chronicle`.
  See [`AGENTS.md`](AGENTS.md) for the full first-run TCC setup.
- **Microphone TCC permission** — grant `chronicle.app` (bundle ID
  `com.victor-software-house.chronicle`) under System Settings → Privacy
  & Security → Microphone.
- **Screen & System Audio Recording TCC permission** — grant
  `chronicle.app` under System Settings → Privacy & Security → Screen
  & System Audio Recording. Without it, `chronicle sysaudio` fails fast
  in ~5 s with a clear remediation error — it does not hang.
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

# Live mic as a daemon: lossless audio + rolling live snapshot + final-only log + JSON trace.
.build/release/chronicle mic \
  --locale pt-BR \
  --live out/live.md \
  --append out/finals.md \
  --save-audio out/audio.wav \
  -o out/trace.json

# Live system-audio capture (everything playing through the default output device).
.build/release/chronicle sysaudio \
  --locale en-US \
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
```

## End-to-end pipeline

A five-stage pipeline (classify → transcribe → diarize → tag → summarize)
exists at `spikes/scripts/run-pipeline.sh`. It chains the subcommands and
produces a single output directory per session. Total wall-clock for the
2026-05-13 6870 s Zoom session: **57 s**.

## Live capture daemons (real-time, multi-sidecar)

Both `mic` and `sysaudio` are long-lived daemons that share the same
pipeline shape. They differ only in the `AudioSource` implementation:
`mic` taps `AVAudioEngine.inputNode`, `sysaudio` taps `SCStream` for the
system default-output mix.

```text
AudioSource (MicAudioSource | SysAudioSource)
  → BufferConverter (→ 16 kHz Int16 mono)
  → fan-out via two AsyncStreams:
      ├─ AsyncStream<AnalyzerInput> → SpeechAnalyzer + .progressiveTranscription [ANE]
      │    → volatile / final events → TranscriptionSink fan-out:
      │        ├─ LiveFileSink     → live.md     (atomic rewrite per event, ~150 ms cadence)
      │        ├─ FinalsAppendSink → finals.md   (timestamped append per phrase)
      │        └─ [JSONLTraceSink — P3]
      └─ AsyncStream<PCMBufferRef>  → audio sidecar sinks (today: WAV; P11: Opus + scratch).
```

Resource cost per daemon: **~0.5–0.8 % CPU, ~30 MB RSS, ~115 MB/h of
lossless WAV (Opus drops this to ~12 MB/h once P11 lands), ~10 KB/s of
text sidecars, ~150 ms volatile latency, 5–30 s final latency.** The model
runs off-process on the ANE; the daemon just does the tap + convert +
fan-out + file writes. On M4 Pro / 48 GB the ANE + RAM headroom supports
~100–200 parallel real-time streams — the actual bottleneck is the audio
device / TCC ceiling.

Full receipts (spike-era):
[`spikes/2026-05-13-daemon-live-mic.md`](spikes/2026-05-13-daemon-live-mic.md).
Note: that spike's source-code layout is now historical; the production
shape follows [ADR-0001](docs/adr/ADR-0001-modular-pipeline-architecture.md).

### `sysaudio` capture scope

`SCStream` captures the mix going to the macOS **default audio output
device** at the time of capture. Apps routing audio to other devices (a
specific HDMI out, an audio interface bypass, etc.) **bypass** capture.
`--include-self-audio` opts chronicle's own audio back in (default is
excluded to prevent feedback loops). When the captured WAV is silent but
the daemon is otherwise healthy, run with `--verbose` to see per-buffer
amplitude diagnostics every ~1.2 s.

## Running it under the Pi process tool

For a chronicle-style 24/7 setup, run as a background process:

```sh
# via pi process tool (preferred — captures stdout/stderr, alerts on failure):
process action=start name=chronicle-mic-live \
  command='cd <repo> && exec .build/release/chronicle mic --locale pt-BR --live <vault>/live.md --append <vault>/finals.md --save-audio <vault>/audio.wav -o <vault>/trace.json'

# or raw nohup if you prefer:
nohup .build/release/chronicle mic --locale pt-BR \
  --live  ~/chronicle/live.md \
  --append ~/chronicle/finals.md \
  --save-audio ~/chronicle/audio.wav \
  -o ~/chronicle/trace.json &> ~/chronicle/daemon.log &
```

The daemon handles `SIGTERM` cleanly —
`finalizeAndFinishThroughEndOfInput()` flushes the last in-flight volatile
into a final before closing, so `finals.md` and the JSON trace stay
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
    │   ├── SysAudioSource.swift   ScreenCaptureKit / SCStream impl
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
    │   └── FinalsAppendSink.swift     timestamped append finals.md
    └── Runtime/
        ├── SignalHandler.swift        SIGINT/SIGTERM one-shot wait
        └── AtomicFile.swift           atomic-write + append-line primitives
```

`Package.swift` embeds `Info.plist` via `-sectcreate` so the OS recognises
the binary as a real app for TCC dialogs (required for the Microphone
prompt on `mic` and the Screen Recording attribution on `sysaudio`).

Future phases plug into the existing protocols:

- **P3 (FR-2) JSONL trace** — add `JSONLTraceSink: TranscriptionSink`.
- **P4 (FR-6) locale auto-detect** — `Core/Speech/LocaleResolver.swift`.
- **P5 (FR-4) live diarization** — `Core/Audio/BufferMulticast.swift` +
  `Core/Diarize/StreamingDiarizer.swift` consuming `PCMBufferRef`.
- **P6 (FR-5) live tagging** — `Core/Sinks/TagsJSONLSink.swift` calling
  the existing `ContentTagger.tagText`.
- **P11 (FR-1 production) ALAC audio sidecar** —
  `Core/Sinks/AVAudioFileALACSink.swift` +
  `Core/Sinks/RollingPCMScratchSink.swift` +
  `Core/Sinks/AudioSidecarCombinators.swift`.
  The default `--audio-format alac` writes rotated ALAC-in-CAF segments and a
  parallel raw-PCM scratch ring.

Diarization is the only non-Apple dependency:
[FluidAudio](https://github.com/FluidInference/FluidAudio) — Apple ships no
public diarizer on Tahoe 26.

## Tests

```sh
swift test
```

`Tests/ChronicleTests/` uses Swift Testing (`@Test`). 24 tests across 6
suites (`AVAudioFile ALAC sink`, `OpusCAFSink`, `RollingPCMScratchSink`,
`TCCPreflight`, `AsyncTimeout`, `EncodeOpus round-trip`). More tests land
alongside each FR per the PRD-001 file breakdown (`JSONLTraceSinkTests`,
`LocaleResolverTests`, `CoreAudioTapSourceTests`, etc.).

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

Manual scratch recovery until `chronicle repair` grows scratch export:

```sh
cat audio/scratch/session/*.pcm > /tmp/recovered.s16le
ffmpeg -f s16le -ar 16000 -ac 1 -i /tmp/recovered.s16le recovered.wav
```

If `format.json` says `commonFormat` is `float32`, use `-f f32le` instead of
`-f s16le`.

Verification receipts:

* `AVAudioFile` ALAC probe on the 6870 s Zoom reference:
  `alac`, `s16p`, 16 kHz mono, 91,316,352 bytes, decoded PCM `cmp-ok`.
* Live mic smoke with `--rotate-audio 1` produced two readable ALAC CAF segments
  plus scratch PCM.

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
