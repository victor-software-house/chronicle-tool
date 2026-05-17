---
title: "Resilient multi-source chronicle daemon"
prd: PRD-001
status: Draft
owner: "Victor"
issue: "N/A"
date: 2026-05-13
version: "1.0"
---

# PRD: Resilient multi-source chronicle daemon

---

## 1. Problem & Context

The current `chronicle mic` binary is a working real-time daemon: it taps the
microphone via `AVAudioEngine`, feeds buffers into Apple's `SpeechAnalyzer`
on the Neural Engine, and writes four sidecar streams (`audio.wav`,
`live.md`, `finals.md`, `trace.json`). Measured cost is 0.5-0.8% of one
core, 30 MB RSS, \~150 ms volatile latency.

For chronicle's 24/7 use-case, three structural gaps remain:

1. **Audio recording is fragile.** `AVAudioFile` writes a WAV header with a
   placeholder data-chunk size at open and patches the real size in on
   `close()`. A crash, OS shutdown, or power loss mid-stream leaves a file
   with a stale or zero size field — bytes are on disk but most players
   reject the file. The current daemon produces **one big WAV per run**,
   so any incident can corrupt the entire session.
2. **Transcript trace is fragile.** `trace.json` is written only at
   graceful shutdown. A crash loses the entire JSON event trace. `finals.md`
   and `live.md` remain intact, but the rich per-event timing data is
   gone.
3. **Single audio source only.** Chronicle wants both microphone **and**
   system audio captured simultaneously, with a unified speaker-labeled
   transcript. The mic side is wired; system audio is now wired through
   CoreAudio process taps, but there is still no diarization in the live path.

This PRD scopes the daemon's evolution from "single-mic working spike" to
"24/7-grade chronicle capture surface with crash-resistant audio,
incremental trace persistence, dual-source capture, live diarization, and
opportunistic live tagging".

The implementation already validated on this machine (10 working
subcommands, all on-device, all $0) is the foundation; this PRD turns it
into a system the operator can leave running.

---

## 2. Goals & Success Metrics

| Goal                         | Metric                                                    | Target                                                                                |
| ---------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **Crash-resistant audio**    | Worst-case audio data loss after an unclean termination   | ≤ 60 s of audio (vs current "entire session unplayable")                              |
| **Crash-resistant trace**    | Worst-case event-trace loss after unclean termination     | ≤ 5 s of events (vs current "entire trace lost")                                      |
| **Dual-source live capture** | Concurrent mic + system audio with one unified transcript | Mic + sysaudio daemons run side by side, finals merge by wall-clock with speaker tags |
| **Live diarization**         | Speaker label attached to each finalized transcript line  | ≥ 80% of finals carry a `speakerId` within 1 s of the line being committed            |
| **Live tagging**             | Topic / entity tags computed on each new final            | ≤ 8 s from final commit to tags landing in a sidecar JSON                             |
| **Resource ceiling**         | Aggregate cost of all live daemons on M4 Pro              | ≤ 5% CPU, ≤ 200 MB RSS for the full mic + sysaudio + tagger + diarizer setup          |

**Guardrails (must not regress):**

* Current single-daemon footprint stays under 1% CPU, 50 MB RSS.
* Volatile latency must not regress beyond \~200 ms.
* All sidecars stay on-device. No cloud calls. No network. No paid APIs.
* The atomic-rewrite contract on `live.md` is preserved (readers never see
  a partial file).

---

## 3. Users & Use Cases

### Primary: chronicle operator (the human running this Mac 24/7)

> As the operator, I want every spoken word to be captured to a recoverable
> audio file and a live transcript even if my Mac crashes, sleeps badly,
> or runs out of battery, so that I never lose a meaningful moment to a
> brittle recorder.

**Preconditions:** the daemon is launched at login; TCC permissions for
Microphone and Screen Recording are granted; Apple Intelligence is
enabled.

### Primary: chronicle daemon supervisor (Pi `process` tool or `launchd`)

> As the supervisor, I want clean termination on `SIGTERM`, fast restart,
> and per-segment rotation so that I can swap out daemons, rotate logs,
> and audit running state without losing audio or transcripts.

### Secondary: chronicle review tooling

> As the downstream offline batch (`transcribe`, `diarize`, `tag`,
> `summarize`, premium STT), I want stable, valid WAV segments and a
> per-event timing trace so that I can re-process the chronicle without
> the original daemon being involved.

### Future: chronicle search / agent layer (enabled by this work)

> As an LLM agent reading chronicle history, I want speaker-labeled,
> timestamped, taggable finals available within seconds of being spoken
> so that I can answer "what did Victor decide in the last hour?" from
> live memory.

---

## 4. Scope

### In scope

1. **Segmented audio capture** — rotate the WAV output every N seconds (default 60 s) into `audio/session-<index>.wav`. Each segment closes cleanly before the next opens; worst-case loss = current segment.
2. **Incremental trace persistence** — flush a rolling JSONL trace (`trace.jsonl`) every K events (default every 1 s or 50 events, whichever is sooner). The legacy `trace.json` becomes a final snapshot, but JSONL is the durable source.
3. **System audio capture subcommand** — `chronicle sysaudio` uses a CoreAudio process tap (`CoreAudioTapSource`) and runs it through the same SpeechAnalyzer pipeline. Same sidecar surface as `chronicle mic` (`--live`, `--append`, `--save-audio`, `-o`). The earlier ScreenCaptureKit implementation remains as deprecated source evidence only; ADR-0004 replaced it after Tahoe ad-hoc builds produced silent/garbage SCStream audio.
4. **Live diarization** — extend `chronicle mic` (and `chronicle sysaudio`) with `--diarize` flag that fans the same audio buffers into FluidAudio's `SortformerDiarizer`. Speaker labels are merged into the transcript finals (`speakerId` field in the JSONL trace, `[S2] <text>` prefix in `finals.md`).
5. **Live content tagging** — extend `mic` / `sysaudio` with `--tag-every <N>` flag. Every Nth final triggers a `FoundationModels` `.contentTagging` pass on the rolling transcript window; results are emitted into a `tags.jsonl` sidecar.
6. **Language auto-detect** — when `--locale auto` is passed, run `NLLanguageRecognizer` on the first 5 finalized segments and switch the transcriber locale once a dominant language is detected with confidence > 0.7. Re-evaluate every 5 minutes for code-switching.
7. **Cross-stream merge** — new `chronicle merge` subcommand that takes two or more `finals.md` files and produces one chronological speaker-labeled transcript. Source-stream prefix (`[mic|sys] [S2] …`) is preserved.
8. **Crash recovery helpers** — `chronicle scratch-export <scratch-dir>` reads raw PCM scratch (`format.json` + `.pcm` segments) and emits WAV or ALAC-in-CAF. Legacy WAV tail repair remains scoped to malformed WAV files from older/opt-in flows.

### Out of scope / later

| What                               | Why                                                                                                                           | Tracked in |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------- |
| Whisper-style hallucination filter | The Tahoe `SpeechTranscriber` does not exhibit the silence-hallucination problem we hit with Whisper. Premature optimisation. | future PRD |
| Continuous diarizer-only output    | `SortformerDiarizer` is fast enough to run inline; standalone path unnecessary.                                               | future PRD |
| Direct push to Obsidian vault      | Out-of-process; better solved by a chronicle → vault watcher.                                                                 | future PRD |
| Encrypted at-rest sidecars         | The full chronicle privacy story is its own PRD.                                                                              | future PRD |
| launchd plist / login item         | Operator currently uses Pi `process` tool. launchd is the right answer post-MVP.                                              | future PRD |

### Design for future (build with awareness)

* All subcommands share a common `Sidecar` protocol (a struct that owns a
  rolling `LiveState`, optional `append` path, optional `live` path, and
  optional `audio` writer). This makes adding `sysaudio` mechanical: same
  protocol, different audio source.
* The diarizer is a *consumer* of the same buffer stream the analyzer
  uses. Build the fan-out as a multicast `AsyncStream`-style helper rather
  than wiring two taps. Future consumers (sound classifier, biometric
  signal extractor, whatever) hook into the same fan-out.
* Tagger output is a JSON-Lines sidecar, one tag-set per line. Easy to
  tail, easy to merge, easy to consume downstream. No DB lock-in.

---

## 5. Functional Requirements

### FR-1: Segmented audio capture (`--rotate-audio <seconds>`, default codec = ALAC-in-CAF)

The mic and sysaudio daemons capture audio via a sink protocol
(`AudioSidecarSink`). The **production default sink is `AVAudioFileALACSink`**
(ALAC-in-CAF fed by rounded Int16 PCM, per [ADR-0002](../adr/ADR-0002-audio-storage-format.md) amended 2026-05-16 after Opus failed the real-reference WER gate). `WAVSidecarSink` is retained for debugging and broad tool compatibility; `OpusCAFSink` is retained only as an explicit opt-in/export sink.

Current P11 wiring composes the default ALAC sidecar with a parallel
`RollingPCMScratchSink`, and rotates finalized ALAC/WAV/Opus sidecars by audio
duration via `--rotate-audio` (default 60 s; `0` disables rotation). Explicit
`--audio-format pcm` selects scratch-only mode.

Crash model: `--rotate-audio 60` bounds the active ALAC segment's finalization
exposure to roughly one minute, but it does **not** mean Chronicle expects to
lose one minute of audio. The parallel scratch tier is append-only raw PCM with
no header/finalization step. If the active CAF is unreadable after a hard kill,
the recent audio is still recoverable from `audio/scratch/<session>/*.pcm` up to
the scratch TTL. Actual unrecoverable loss is limited to the final buffer/write
that did not reach disk, not the whole active ALAC segment. Automated scratch
export/repair is implemented as `chronicle scratch-export`; manual ffmpeg
recovery remains a fallback/debug path.

**Acceptance criteria:**

```gherkin
Given the daemon is running with --save-audio session.caf --audio-format alac --rotate-audio 60
When audio streams and the daemon exits cleanly
Then audio/session-000001.caf and later finalized segments reopen with AVAudioFile as ALAC-in-CAF
And RollingPCMScratchSink writes bit-exact PCM under audio/scratch/session/
And a hard kill can damage only the active CAF segment's finalization metadata while recent scratch PCM remains decodable from the last successful write
And the on-disk size of the 6870 s Zoom reference is near the verified rounded-Int16 ALAC target (~91.3 MB)
And decoded PCM matches the rounded Int16 source control
And WER delta versus the WAV baseline is ≤ 1 %
```

```gherkin
Given the daemon is running with --save-audio session.wav --audio-format wav --rotate-audio 60
When 130 seconds of audio have streamed and the daemon is killed with SIGKILL
Then audio/session-000001.wav and audio/session-000002.wav are valid WAVs
And audio/session-000003.wav contains the last ~10 seconds and may have a stale header
And running `chronicle repair audio/session-000003.wav` produces a valid WAV
And concatenating all three reconstructs the full session
```

```gherkin
Given the daemon is running with --audio-format pcm
When the operator triggers an on-demand premium-STT pass on a segment that finalised 90 seconds ago
Then the segment is available in audio/scratch/ at bit-exact PCM
And the daemon evicts scratch segments older than the configured TTL (default 300 s) automatically

Given the daemon runs with the default ALAC sidecar
When incoming PCM duration crosses --rotate-audio
Then a new numbered ALAC CAF segment starts at the next input buffer
And each finalized segment reopens through AVAudioFile
```

**Scratch recovery:**

```sh
# WAV output (inferred from .wav).
chronicle scratch-export audio/scratch/session -o recovered.wav

# ALAC-in-CAF output.
chronicle scratch-export audio/scratch/session -o recovered.caf --format alac
```

`scratch-export` reads `format.json`, validates canonical interleaved scratch
layout, requires contiguous numbered `.pcm` files, trims partial trailing frames,
and writes a standard audio file through AVFoundation. Manual ffmpeg recovery
is still possible for debugging (`-f s16le` for `commonFormat=int16`, `-f f32le`
for `commonFormat=float32`).

**Files:**

* `Sources/Chronicle/Core/Sinks/AVAudioFileALACSink.swift` — production default: `AVAudioFile(forWriting:)` configured for CAF + `kAudioFormatAppleLossless`, `AVEncoderBitDepthHintKey: 16`, and rounded Int16 PCM buffers. Probe result on the 6870 s reference: `alac`, `s16p`, 16 kHz mono, 91,316,352 bytes, decoded PCM `cmp-ok`.
* `Sources/Chronicle/Core/Sinks/WAVSidecarSink.swift` — debug/export sink.
* `Sources/Chronicle/Core/Sinks/OpusCAFSink.swift` — opt-in/export sink only; rejected as default after WER regression on the 6870 s reference.
* `Sources/Chronicle/Core/Sinks/RollingPCMScratchSink.swift` — bounded-size append-only ring of raw PCM, auto-prunes past TTL; runs in parallel with default ALAC and remains available as scratch-only `--audio-format pcm`.
* `Sources/Chronicle/Core/Sinks/AudioSidecarCombinators.swift` — composite sink fan-out plus audio-duration-based rotating sidecar wrapper.
* `Sources/Chronicle/Subcommands/Mic.swift` / `Sources/Chronicle/Subcommands/SysAudio.swift` — wire `--audio-format`, `--rotate-audio`, `--scratch-ttl`, and `--scratch-rotate` flags into the pipeline.
* `Sources/Chronicle/Core/Sinks/ScratchExporter.swift` — scratch manifest reader/exporter for contiguous raw PCM segments.
* `Sources/Chronicle/Subcommands/ScratchExport.swift` — CLI wrapper for scratch recovery to WAV or ALAC-in-CAF.
* `Sources/Chronicle/Subcommands/Repair.swift` — future legacy WAV/tail repair for the `--audio-format wav` opt-in path and older incident artefacts.

---

### FR-2: Incremental JSONL trace (`-o trace.jsonl` overrides `trace.json`)

Every event is appended as one JSON object on its own line, flushed every
K events. The legacy `trace.json` snapshot is still written on graceful
shutdown but the JSONL is the source of truth.

**Acceptance criteria:**

```gherkin
Given the daemon is running with -o trace.jsonl
When the operator kills -9 the process after 30 seconds
Then trace.jsonl is well-formed JSON-Lines (one event per line)
And at most one trailing line is partially written
And `jq -c . trace.jsonl 2>/dev/null | wc -l` is within 5 events of the true count
```

**Files:**

* `Sources/Chronicle/Mic.swift` — replace `trace.json` writer with JSONL appender.
* `Sources/Chronicle/Live.swift` — same pattern.

---

### FR-3: System audio subcommand (`chronicle sysaudio`)

A subcommand that captures system audio via CoreAudio process tap
(`CATapDescription` + private aggregate device) and runs it through the same
SpeechAnalyzer pipeline. Identical sidecar surface to `mic`.

**Acceptance criteria:**

```gherkin
Given Apple Intelligence is enabled and System Audio Recording TCC is granted for chronicle.app
When `chronicle sysaudio --locale en-US --live live.md --append finals.md --save-audio audio/sys.caf` is launched
And spoken audio is played through the default output device
Then live.md updates within ~150 ms of speech in the audio being audible
And finals.md captures the spoken content with locale-appropriate accuracy
And the ALAC sidecar reopens through AVAudioFile
And raw PCM scratch is written under audio/scratch/
```

**Implemented receipts (2026-05-17):**

* Live smoke through `.build/release/chronicle.app/Contents/MacOS/chronicle sysaudio --seconds 7` plus `say "final guard chronicle core audio tap test"` captured one final: `Final Guard Chronicle Core audio tap test.`
* `afinfo` reopened `/tmp/chronicle-sysaudio-final2/audio/sys-000001.caf` as ALAC-in-CAF, mono 16 kHz, 7.19 s.
* Raw scratch wrote `/tmp/chronicle-sysaudio-final2/audio/scratch/sys/000000.pcm` plus `format.json`.

**Files:**

* `Sources/Chronicle/Core/Audio/CoreAudioTapSource.swift` — CoreAudio process tap source; creates a `CATapDescription`, private aggregate device, IOProc, default-output listener, and first-valid-buffer watchdog.
* `Sources/Chronicle/Subcommands/SysAudio.swift` — CLI wrapper using `CoreAudioTapSource`.
* `Info.plist` — includes `NSAudioCaptureUsageDescription` plus existing speech/mic strings.
* `Sources/Chronicle/Core/Audio/SysAudioSource.swift` — deprecated ScreenCaptureKit implementation retained for reference/tests only.

---

### FR-4: Live diarization (`--diarize`)

`mic` and `sysaudio` accept `--diarize`. When set, the same buffers fed
into the analyzer are also fed into FluidAudio's `SortformerDiarizer`.
Speaker IDs are merged into each final by aligning audio ranges.

**Acceptance criteria:**

```gherkin
Given chronicle mic --locale pt-BR --diarize is running
And two speakers (A, B) take turns speaking for 60 seconds
When the daemon emits finals
Then each final in finals.md is prefixed with the speakerId, e.g. "[S1] olá" / "[S2] tudo bem"
And the JSONL trace event objects carry a "speakerId" field
And the speaker count converges to 2 within the first ~10 seconds
```

**Files:**

* `Sources/Chronicle/Mic.swift` — add buffer multicast; spawn diarizer task.
* `Sources/Chronicle/Diarize.swift` — extract `SortformerDiarizer` setup into a shared streaming helper.
* `Sources/Chronicle/SysAudio.swift` — same flag.

---

### FR-5: Live content tagging (`--tag-every <N>`)

Every N finals trigger a `FoundationModels` `.contentTagging` pass over
the rolling cumulative transcript (most recent \~5000 chars). Results are
appended to `tags.jsonl` as one JSON record per pass.

**Acceptance criteria:**

```gherkin
Given chronicle mic --tag-every 3 is running on a fresh session
When the model emits the 3rd, 6th, and 9th finals
Then tags.jsonl has 3 entries
And each entry includes elapsedSeconds, topics, entities, actions, and the cumulative text size at trigger
And the latency between the 3rd final and its tag entry is < 8 seconds
```

**Files:**

* `Sources/Chronicle/Mic.swift` — debounce tagger triggers on each final.
* `Sources/Chronicle/Tag.swift` — extract a reusable `tagText(_:)` function that does not require CLI args.

---

### FR-6: Locale auto-detect (`--locale auto`) with candidate-set restriction

Locale resolution is governed by [ADR-0003](../adr/ADR-0003-locale-resolution-policy.md). Four modes:

* **Pin** (`--locale en-US`): no detection runs; the transcriber stays at the pinned locale. **This is the operator's "disable auto" switch.**
* **Auto with default safe set** (`--locale auto`): candidates = operator's configured primary languages (default `[en-US, pt-BR]`; overridable via `~/.config/chronicle/locales.json`). `NLLanguageRecognizer` is configured with `setLanguageConstraints([...])` so it can only return candidates from the safe set.
* **Auto with explicit set** (`--locale auto:en-US,pt-BR,es-ES`): per-run candidate list.
* **Auto with full supported set** (`--locale auto:*`): opt-in only; documented as research mode; never picked silently.

Hysteresis (modes auto / auto:list / auto:\*):

* Detector runs on **finals only** (volatile is too noisy by an order of magnitude).
* Switch requires **N consecutive finals** (`--locale-min-finals`, default 3) agreeing on the same candidate, **with confidence ≥ `--locale-confidence`** (default 0.70).
* Switch **suppressed for `--locale-cooldown-sec`** (default 30 s) after the previous switch.
* Switch **suppressed if fewer than `--locale-min-chars`** (default 30) total characters have been observed at the candidate locale across the consecutive-final window — single loanwords don't trigger a flip.
* Initial locale = first candidate in the set (so the default `[en-US, pt-BR]` starts in `en-US`).

**Acceptance criteria:**

```gherkin
Given chronicle mic --locale auto is running with the default safe set [en-US, pt-BR]
And the operator speaks Portuguese
When 3 consecutive finals are detected as pt-BR with confidence ≥ 0.70 and total ≥ 30 chars
Then stderr logs "[mic] auto-detected locale=pt-BR (was en-US), restarting transcriber"
And subsequent finals are coherent Portuguese (no English misinterpretation)
```

```gherkin
Given chronicle mic --locale auto is running with the default safe set [en-US, pt-BR]
When a stretch of audio contains noise + a single Russian-sounding loanword
Then the transcriber locale does NOT switch to ru-RU
And ru-RU is not even a candidate because it is not in the safe set
And `live.md` stays in the current locale
```

```gherkin
Given chronicle mic --locale en-US is running (pin mode)
When Portuguese speech arrives
Then no detection runs
And the transcriber stays at en-US
And this is the operator's explicit disable-auto switch
```

```gherkin
Given chronicle mic --locale auto is running
And a locale switch happened 5 seconds ago
When 3 consecutive finals detect a different candidate at confidence ≥ 0.70
Then the switch is suppressed because the 30 s cooldown has not elapsed
```

**Files:**

* `Sources/Chronicle/Core/Speech/LocaleResolver.swift` — owns the candidate set, runs the hysteresis state machine, exposes `consider(final:) -> Locale?` returning a new locale only when all gates pass.
* `Sources/Chronicle/Subcommands/Mic.swift` / `SysAudio.swift` / `Live.swift` — parse `--locale` grammar, build the resolver, swap transcribers on resolver output.
* `~/.config/chronicle/locales.json` — optional operator-specific safe set; absence → built-in default `[en-US, pt-BR]`.
* `Tests/ChronicleTests/Speech/LocaleResolverTests.swift` — unit tests covering in-set switch, out-of-set suppression, cooldown suppression, min-chars suppression, pin-mode bypass.

---

### FR-7: Cross-stream merge (`chronicle merge`)

A standalone subcommand that takes ≥2 `finals.md` files (or JSONL traces)
and emits one chronological, source-prefixed, speaker-labeled markdown
log on stdout.

**Acceptance criteria:**

```gherkin
Given finals-mic.md and finals-sys.md both exist with interleaved timestamps
When `chronicle merge finals-mic.md finals-sys.md` is run
Then stdout is a chronological markdown table sorted by ISO timestamp
And each line is prefixed with its source ("[mic]" / "[sys]")
And speaker labels (if present) are preserved
```

**Files:**

* `Sources/Chronicle/Merge.swift` — new subcommand.

---

### FR-8: Crash recovery helpers (`chronicle scratch-export`, future `chronicle repair`)

Scratch recovery is implemented through `chronicle scratch-export`: it reads a
scratch directory containing `format.json` plus contiguous numbered `.pcm`
segments, trims partial trailing frames, and writes a standard WAV or
ALAC-in-CAF file.

Legacy WAV repair remains future work: a standalone `chronicle repair <wav>`
should take a WAV file with a malformed header and rewrite size fields based on
the actual file size on disk.

**Acceptance criteria:**

```gherkin
Given a scratch directory produced by RollingPCMScratchSink
When `chronicle scratch-export audio/scratch/session -o recovered.wav` is run
Then `recovered.wav` reopens with AVAudioFile
And Int16 mono, Int16 stereo interleaved, and Float32 mono scratch inputs preserve sample values
And partial trailing frames are trimmed instead of poisoning the output
And missing or invalid manifests fail with actionable errors
And missing middle segments fail before output is trusted
```

```gherkin
Given a WAV file produced by an interrupted recording (header data-chunk size = 0)
When `chronicle repair session-003.wav` is run
Then the file's header is rewritten with the correct size fields
And the file plays correctly in `afplay` and `ffmpeg`
And `chronicle transcribe -i session-003.wav -o out` succeeds without errors
```

**Files:**

* `Sources/Chronicle/Core/Sinks/ScratchExporter.swift` — implemented scratch export core.
* `Sources/Chronicle/Subcommands/ScratchExport.swift` — implemented `chronicle scratch-export` CLI.
* `Sources/Chronicle/Subcommands/Repair.swift` — future legacy WAV repair subcommand.

---

## 6. Non-Functional Requirements

| Category               | Requirement                                                                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Performance**        | Single daemon: ≤ 1% CPU, ≤ 50 MB RSS. Full mic + sysaudio + diarize + tag stack: ≤ 5% CPU, ≤ 200 MB RSS.                                                |
| **Latency**            | Volatile transcript updates: ≤ 200 ms. Final commit: ≤ 30 s. Live diarization: ≤ 1 s after final. Live tagging: ≤ 8 s after triggering final.           |
| **Resilience**         | After `SIGKILL` or power loss: audio loss ≤ 60 s, trace event loss ≤ 5 s. All other previously-committed events recoverable from disk.                  |
| **Privacy**            | All processing on-device. No network calls. No telemetry. No paid APIs.                                                                                 |
| **Portability**        | macOS 26+ only. Apple Silicon only. No fallback path for older OS / Intel.                                                                              |
| **File compatibility** | Audio sidecars must be readable by `ffmpeg`, `afplay`, and our own offline `transcribe` without modification (except for repair-needing tail segments). |

---

## 7. Risks & Assumptions

### Risks

| Risk                                                                                                                            | Severity | Likelihood                    | Mitigation                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------- | -------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **R-A1: compressed audio decode degrades `SpeechAnalyzer` accuracy vs WAV reference**                                           | High     | Proven for Opus; low for ALAC | P11 rejected Opus as default after real 6870 s Zoom WER drift. Default is now ALAC-in-CAF with rounded Int16 source PCM per [ADR-0002](../adr/ADR-0002-audio-storage-format.md). Acceptance test: re-transcribe the 2026-05-13 reference after ALAC round-trip and assert WER delta ≤ 1 % vs WAV baseline; keep WAV/PCM as escape hatches. |
| **R-A2: system audio capture permission / backend drift**                                                                         | Medium   | Medium                        | ADR-0004 replaced SCStream with `CoreAudioTapSource` because ad-hoc Tahoe builds require CoreAudio process taps for reliable system audio. CLI now uses CoreAudio tap, validates tap ASBD before conversion, requires `.app` bundle TCC identity, and keeps a first-valid-buffer watchdog.                                                                                                                                                                                         |
| Legacy `SysAudioSource` / SCStream path rots while retained for reference/tests                                                | Low      | Medium                        | CLI uses `CoreAudioTapSource`; keep SCStream code deprecated and delete after one release if no future video/screen path needs it.                                                                                                                                                                                                           |
| `SortformerDiarizer` adds per-buffer latency that pushes volatile updates beyond the 200 ms NFR                                 | Medium   | Low                           | Run the diarizer in a separate `Task` reading from the multicast stream; do not let it block the analyzer's stream. Measure on the 6870 s reference session.                                                                                                                                                                               |
| Foundation Models live tagging trips the safety guardrail (`Detected content likely to be unsafe`) on certain transcript chunks | Low      | Medium                        | Catch the error, skip the chunk, log a warning to stderr, continue. Already seen on the mic JSON test.                                                                                                                                                                                                                                     |
| Audio rotation creates "gaps" between segments because `installTap` keeps delivering buffers during file swap                   | Medium   | Medium                        | Lock the rotation in a serial queue; buffer the in-flight buffer until the new file is ready (≤ 50 ms swap). Worst case: one buffer (\~85 ms) overlap, never a gap. CAF packet boundaries are independent so the Opus sink doesn't see this risk; only `WAVSidecarSink` (opt-in) does.                                                     |
| Cross-process file races (two daemons writing the same sidecar file)                                                            | Low      | Low                           | Each daemon writes its own sidecar set under a distinct subdirectory; `merge` does the unification offline. Document the convention.                                                                                                                                                                                                       |
| Language auto-detect false-flip mid-conversation due to a single foreign word                                                   | Medium   | Medium                        | Mitigated by [ADR-0003](../adr/ADR-0003-locale-resolution-policy.md): mandatory candidate-set restriction (default `[en-US, pt-BR]`), 4-knob hysteresis (confidence ≥ 0.70, ≥ 3 consecutive finals, 30 s cooldown, ≥ 30 chars at new locale). Operator can disable detection entirely by pinning `--locale en-US`.                         |

### Assumptions

* The operator runs the daemon under the Pi `process` tool (which sends `SIGTERM` on stop) or launchd; raw `kill -9` is the worst case to design for.
* The Mac's clock is monotonic enough that ISO timestamps from two daemons can be ordered correctly by `merge`. (NTP-synced macOS clocks are.)
* The `SystemLanguageModel` 23-locale set is sufficient for now; minority languages fall back to whisper.cpp via the offline `transcribe` path.
* FluidAudio's `SortformerDiarizer` actually works as documented (up to 4 speakers, 480 ms latency). The offline `DiarizerManager` working is good evidence but we haven't validated streaming yet.
* The disk has space. 24/7 capture at 32 KB/s = 2.6 GB/day of audio. We do not auto-prune; that is the storage-tier PRD's job.

---

## 8. Design Decisions

### D1: WAV segmentation vs single-file recorder

**Options considered:**

1. **Single growing WAV with periodic header patch.** Continuously re-`close()` and re-open with `O_APPEND`, patch the size every N seconds. Complex, error-prone, easy to introduce subtle corruption.
2. **Segmented WAVs (`session-NNNNNN.wav`).** Standard pattern, used by every long-running recorder. Trivial to reason about. Concatenate with `ffmpeg -f concat` later.
3. **Raw PCM stream with JSON sidecar header.** No WAV header at all; every byte is recoverable. Requires custom tooling to play / process. Maximally robust but ugliest.

**Decision:** **Segmented WAVs**, default 60 s per segment, 6-digit zero-padded index.

**Rationale:** WAV remains the standard format every macOS tool reads. 60 s is short enough that any one incident loses at most a minute. Segments concatenate trivially via `ffmpeg -f concat`. The crash-recovery helper (FR-8) handles the tail segment if needed.

**Current P11 path:** ADR-0002 supersedes segmented WAV as the default with ALAC-in-CAF, fed by rounded Int16 PCM. The highest-level Apple writer probe passed: `AVAudioFile(forWriting:)` with `kAudioFormatAppleLossless`, CAF output, `AVEncoderBitDepthHintKey: 16`, and `.pcmFormatInt16` buffers produced compact 16-bit-source ALAC that decoded byte-identically to the source PCM. `ExtAudioFile` is fallback-only for future OS regressions. Opus remains opt-in/export only after WER regression on the real reference.

---

### D2: Trace persistence — JSONL vs JSON snapshot

**Options considered:**

1. **Keep `trace.json` (snapshot at shutdown).** Crash loses everything. Current state.
2. **Switch to `trace.jsonl` (one event per line, append-only).** Append is atomic up to `PIPE_BUF`. Lose at most the trailing line.
3. **Write a SQLite WAL.** Overkill for this volume; introduces a dependency for tooling that needs to read the trace.

**Decision:** **JSONL append-only**, flushed every 50 events or every 1 s, whichever is sooner.

**Rationale:** Standard, language-agnostic, jq-friendly. Append is atomic enough at this byte count (\~200 bytes/event ≪ PIPE\_BUF 4096). Recovery is `jq -c . trace.jsonl 2>/dev/null` (jq silently drops the trailing malformed line if any).

**Future path:** if multiple daemons share a trace surface (unlikely), upgrade to a single-writer ingestion service that owns the JSONL file.

---

### D3: System audio — virtual loopback vs CoreAudio tap

**Options considered:**

1. **CoreAudio aggregate device + BlackHole loopback.** Works today, no entitlement needed. Requires installing a kext-like virtual driver. Operator burden.
2. **ScreenCaptureKit `SCStream` audio-only tap.** Native Apple API but unreliable for chronicle's ad-hoc Tahoe builds without Developer ID signing; preserved as deprecated `SysAudioSource` evidence only.
3. **CoreAudio process tap (`CATapDescription` + private aggregate device).** Apple-official system-audio tap API on Tahoe; works with ad-hoc app bundles and no third-party driver.

**Decision:** **CoreAudio process tap** per [ADR-0004](../adr/ADR-0004-tahoe-system-audio-capture.md).

**Rationale:** Live incident + 2026-05-17 smoke showed CoreAudio tap captures real system audio where SCStream produced silent/garbage buffers under the same development identity. It keeps Chronicle zero-install, on-device, and single-binary.

**Future path:** keep SCStream only for future video/screen capture if needed; audio remains CoreAudio tap unless Apple changes the TCC/backend model.

---

### D4: Diarization — fan-out vs pipeline

**Options considered:**

1. **Pipeline (`mic | diarizer`).** Two processes, pipe between them. Loses tight timing alignment.
2. **In-process fan-out via multicast `AsyncStream`.** Same buffers feed both consumers. Tight timing, shared format conversion.

**Decision:** **In-process fan-out.**

**Rationale:** Diarization needs to align with transcript by audio range. Same buffers in both consumers makes the alignment trivial (both work on the same `CMTimeRange` axis). No IPC, no serialisation, no clock drift. Generalised into a reusable `BufferMulticast` primitive — see [ADR-0001](../adr/ADR-0001-modular-pipeline-architecture.md).

**Future path:** when chronicle moves to a service-oriented architecture, expose the buffer stream over Unix sockets / gRPC for out-of-process consumers.

---

### D5: Live tagging cadence

**Options considered:**

1. **Tag on every final.** Each final is short; tagging cost per call is \~5 s. Latency stack-up if speech is fast.
2. **Tag every N finals (debounced).** Reasonable middle ground; debounces but stays current.
3. **Tag on a wall-clock interval (every 60 s).** Decouples from speech rate.

**Decision:** **Every N finals (configurable, default N=3).**

**Rationale:** N=3 gives \~30-90 s of new context per tagger call, which is the right granularity for human-readable tag drift. Wall-clock cadence sleeps when no one is talking, which is wasteful.

**Future path:** add a `--tag-every-seconds` flag for environments where speech rate is variable. Keep `--tag-every <N>` as the default behaviour.

---

## 9. File Breakdown

The codebase is being restructured into a protocol-oriented core with thin
CLI veneers per [ADR-0001](../adr/ADR-0001-modular-pipeline-architecture.md).
FR-by-FR file mapping below reflects the post-refactor layout.

| File                                                          | Change type       | FR                           | Description                                                  |          |
| ------------------------------------------------------------- | ----------------- | ---------------------------- | ------------------------------------------------------------ | -------- |
| `Sources/Chronicle/Chronicle.swift`                           | Modify            | FR-3, FR-7, FR-8             | Register `sysaudio`, `merge`, `repair`                       |          |
| `Sources/Chronicle/Subcommands/Mic.swift`                     | Refactor + extend | FR-1, FR-2, FR-4, FR-5, FR-6 | Becomes a \~60-line orchestration of `Core/` protocols       |          |
| `Sources/Chronicle/Subcommands/SysAudio.swift`                | New               | FR-3, FR-4, FR-5             | New CLI veneer; reuses the same pipeline as `Mic`            |          |
| `Sources/Chronicle/Subcommands/Live.swift`                    | Refactor + modify | FR-2                         | File-driven veneer reusing `Core/Speech`                     |          |
| `Sources/Chronicle/Subcommands/Transcribe.swift`              | Refactor          | n/a                          | Uses `Core/Speech.TranscriptionEngine`                       |          |
| `Sources/Chronicle/Subcommands/Diarize.swift`                 | Refactor          | n/a                          | Uses `Core/Diarize.OfflineDiarizer`                          |          |
| `Sources/Chronicle/Subcommands/Tag.swift`                     | Refactor          | FR-5                         | Delegates to `Core/LLM.ContentTagger.tagText`                |          |
| `Sources/Chronicle/Subcommands/Summarize.swift`               | Refactor          | n/a                          | Delegates to `Core/LLM.Summarizer`                           |          |
| `Sources/Chronicle/Subcommands/Translate.swift`               | Refactor          | FR-6                         | Uses `Core/Speech.LocaleResolver`                            |          |
| `Sources/Chronicle/Subcommands/OCR.swift`                     | Refactor          | n/a                          | Unchanged behaviour, moved into Subcommands/                 |          |
| `Sources/Chronicle/Subcommands/Describe.swift`                | Refactor          | n/a                          | Reuses `Core/LLM.ModelHost`                                  |          |
| `Sources/Chronicle/Subcommands/Merge.swift`                   | New               | FR-7                         | Cross-stream merge of finals/jsonl                           |          |
| `Sources/Chronicle/Subcommands/Repair.swift`                  | New               | FR-1, FR-8                   | WAV header repair                                            |          |
| `Sources/Chronicle/Core/Audio/AudioSource.swift`              | New               | FR-3, FR-4                   | Protocol: yields `AnalyzerInput` + raw PCM                   |          |
| `Sources/Chronicle/Core/Audio/MicAudioSource.swift`           | New               | FR-1                         | `AVAudioEngine` impl                                         |          |
| `Sources/Chronicle/Core/Audio/SysAudioSource.swift`           | New               | FR-3                         | `SCStream` impl                                              |          |
| `Sources/Chronicle/Core/Audio/FileAudioSource.swift`          | New               | n/a                          | `AVAudioFile` impl for file-driven runs                      |          |
| `Sources/Chronicle/Core/Audio/BufferMulticast.swift`          | New               | FR-4, FR-5                   | Lock-free SPMC fan-out, audio-thread safe                    |          |
| `Sources/Chronicle/Core/Audio/BufferConverter.swift`          | New               | n/a                          | `AVAudioConverter` wrapper                                   |          |
| `Sources/Chronicle/Core/Speech/TranscriptionEngine.swift`     | New               | FR-2, FR-6                   | Preset-agnostic `SpeechAnalyzer` wrapper                     |          |
| `Sources/Chronicle/Core/Speech/LocaleResolver.swift`          | New               | FR-6                         | `NLLanguageRecognizer` auto-detect                           |          |
| `Sources/Chronicle/Core/Diarize/Diarizer.swift`               | New               | FR-4                         | Protocol                                                     |          |
| `Sources/Chronicle/Core/Diarize/OfflineDiarizer.swift`        | New               | n/a                          | FluidAudio batch impl                                        |          |
| `Sources/Chronicle/Core/Diarize/StreamingDiarizer.swift`      | New               | FR-4                         | FluidAudio Sortformer impl                                   |          |
| `Sources/Chronicle/Core/LLM/ModelHost.swift`                  | New               | FR-5                         | Cached `LanguageModelSession`                                |          |
| `Sources/Chronicle/Core/LLM/ContentTagger.swift`              | New               | FR-5                         | `@Generable` + `tagText()`                                   |          |
| `Sources/Chronicle/Core/LLM/Summarizer.swift`                 | New               | n/a                          | `@Generable` + `summarizeText()`                             |          |
| `Sources/Chronicle/Core/LLM/ImageDescriber.swift`             | New               | n/a                          | Vision multi-request + FM narration                          |          |
| `Sources/Chronicle/Core/Sinks/TranscriptionSink.swift`        | New               | FR-2, FR-4, FR-5             | Protocol: \`didReceive(volatile                              | final)\` |
| `Sources/Chronicle/Core/Sinks/LiveFileSink.swift`             | New               | n/a                          | Atomic-rewrite `live.md`                                     |          |
| `Sources/Chronicle/Core/Sinks/FinalsAppendSink.swift`         | New               | n/a                          | Append-per-final timestamped log                             |          |
| `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift`           | New               | FR-2                         | Incremental JSONL trace                                      |          |
| `Sources/Chronicle/Core/Sinks/TagsJSONLSink.swift`            | New               | FR-5                         | Tags every N finals                                          |          |
| `Sources/Chronicle/Core/Sinks/AVAudioFileALACSink.swift`      | New               | FR-1                         | Default ALAC-in-CAF sidecar via high-level `AVAudioFile`     |          |
| `Sources/Chronicle/Core/Sinks/WAVSidecarSink.swift`           | New               | FR-1                         | Opt-in/debug WAV writer                                      |          |
| `Sources/Chronicle/Core/Sinks/OpusCAFSink.swift`              | New               | FR-1                         | Opt-in/export Opus-in-CAF writer                             |          |
| `Sources/Chronicle/Core/Sinks/RollingPCMScratchSink.swift`    | New               | FR-1                         | Bounded raw-PCM scratch ring                                 |          |
| `Sources/Chronicle/Core/Runtime/SignalHandler.swift`          | New               | n/a                          | `SIGINT`/`SIGTERM` one-shot helper                           |          |
| `Sources/Chronicle/Core/Runtime/AtomicFile.swift`             | New               | FR-2                         | Atomic-write + JSONL append primitives                       |          |
| `Sources/Chronicle/Core/Runtime/LivePipeline.swift`           | New               | FR-1…FR-5                    | Orchestrator: source → \[consumers] → \[sinks]               |          |
| `Tests/ChronicleTests/Audio/BufferMulticastTests.swift`       | New               | FR-4                         | SPMC fan-out unit tests                                      |          |
| `Tests/ChronicleTests/Sinks/JSONLTraceSinkTests.swift`        | New               | FR-2                         | Crash-recovery (kill mid-write) tests                        |          |
| `Tests/ChronicleTests/Sinks/AVAudioFileALACSinkTests.swift`   | New               | FR-1                         | ALAC/CAF writer readback test                                |          |
| `Tests/ChronicleTests/Sinks/RollingPCMScratchSinkTests.swift` | New               | FR-1                         | Scratch rotation + TTL eviction tests                        |          |
| `Tests/ChronicleTests/Subcommands/RepairTests.swift`          | New               | FR-8                         | Repairs canned malformed WAVs                                |          |
| `Tests/ChronicleTests/Subcommands/MergeTests.swift`           | New               | FR-7                         | Chronological merge with canned finals files                 |          |
| `Tests/ChronicleTests/Speech/LocaleResolverTests.swift`       | New               | FR-6                         | Auto-detect convergence on synthetic inputs                  |          |
| `Tests/ChronicleTests/Helpers/MockAudioSource.swift`          | New               | testing                      | Plays canned WAVs through the live pipeline for E2E coverage |          |
| `Package.swift`                                               | Modify            | testing                      | Add `ChronicleTests` test target                             |          |
| `Info.plist`                                                  | Modify            | FR-3                         | Add `NSScreenCaptureUsageDescription`                        |          |
| `README.md`                                                   | Modify            | all                          | Document new flags, layout, daemon model, recovery story     |          |
| `docs/prd/PRD-001-resilient-multi-source-daemon.md`           | New               | n/a                          | This document                                                |          |
| `docs/adr/ADR-0001-modular-pipeline-architecture.md`          | New               | n/a                          | Sister ADR for the structural decision                       |          |
| `spikes/2026-05-13-daemon-live-mic.md`                        | Modify (later)    | all                          | Add post-implementation receipts                             |          |

Every production file traces to at least one FR. Every FR has at least one
production file and at least one test target. The refactor (P0) lands
*before* the FR implementations so that each FR is built directly into the
new structure with its tests.

---

## 10. Dependencies & Constraints

* **macOS 26+** for `SpeechAnalyzer` (`Speech` framework new API).
* **Apple Silicon** for ANE acceleration; no Intel fallback.
* **Apple Intelligence enabled** for FoundationModels (`tag`, `summarize`, `describe`).
* **Translation language packs** pre-installed for `translate`.
* **Microphone TCC** for `mic` (already wired).
* **Screen Recording TCC** for `sysaudio` (new).
* **FluidAudio 0.14.5+** for `SortformerDiarizer` (Swift Package).
* **Xcode 26 / Swift 6.2+** for the build.
* **`Info.plist` embedded via `-sectcreate`** (Package.swift already does this for Microphone; add Screen Recording).

---

## 11. Rollout Plan

Order each step so the previous one's receipts feed the next.

1. **P0 — Modular refactor + test target** \[DONE 2026-05-13]. Implemented [ADR-0001](../adr/ADR-0001-modular-pipeline-architecture.md): extracted `Core/Audio`, `Core/Speech`, `Core/Diarize`, `Core/LLM`, `Core/Sinks`, `Core/Runtime`; converted each subcommand to a thin veneer; added `ChronicleTests` Swift Package test target; verified behaviour parity (byte-identical transcribe.txt + diarize segments) against the 2026-05-13 Zoom session receipts.
2. **P7 — FR-3: `sysaudio` subcommand** (promoted). Validates the `AudioSource` protocol from ADR-0001 against a real second implementation before the rest of the FRs build on it. Only `SysAudioSource` is new; sidecar sinks reused. Catches TCC / signing friction early; lets the upcoming P11 Opus parity test validate against two real sources.
3. **P11 — FR-1 (ALAC production sink) per [ADR-0002](../adr/ADR-0002-audio-storage-format.md) (amended 2026-05-16).** Implement `AVAudioFileALACSink` + `RollingPCMScratchSink`, wire `--audio-format alac|wav|pcm|opus` to the audio sinks, run the accuracy-parity test against the 2026-05-13 reference session and assert WER delta ≤ 1 % vs the WAV baseline. Flip the default from WAV to ALAC-in-CAF once sidecar wiring is complete. **Skips the transitional WAV-rotation step** (formerly P1) because the verified default is Apple-native ALAC/CAF plus rolling raw scratch. Opus remains opt-in/export only after WER regression on the real reference.
4. **P3 — FR-2: `JSONLTraceSink` resilience.** Incremental trace via `AtomicFile.appendJSONLine`. Unit + crash-recovery tests (`kill -9` simulation).
5. **P4 — FR-6: locale auto-detect** per [ADR-0003](../adr/ADR-0003-locale-resolution-policy.md). `LocaleResolver` with candidate-set restriction + 4-knob hysteresis. Unit tests on synthetic NL inputs covering: correct in-set switch, suppression of out-of-set candidates, suppression during cooldown, suppression below min-chars, pin-mode bypass.
6. **P5 — FR-4: live diarization.** Reuses the existing FluidAudio dep. `BufferMulticast` + `StreamingDiarizer` are unit-testable with `MockAudioSource`. Test against the 2026-05-13 Zoom session offline first, then live.
7. **P6 — FR-5: live tagging.** Once FR-4 lands, tagging is the smallest layer on top via `ModelHost` + `TagsJSONLSink`.
8. **P8 — FR-7: `merge` subcommand.** Pure-function; easy to leave for last and unit-test exhaustively.
9. **P2 — FR-8: `chronicle repair`** (de-prioritised). Mostly needed for the `--audio-format wav` opt-in path and unusual CAF tail recovery; ALAC/CAF plus raw scratch reduces the default repair surface. Canned malformed-WAV corpus tests.
10. **P9 — Verification pass.** Run the §15 appendix end-to-end on a fresh session. Capture receipts.
11. **P10 — Documentation pass.** Update README + research-notes + spike doc with the final source code + final numbers.

---

## 12. Open Questions

| #  | Question                                                                                                                                                                                     | Owner  | Due        | Status                                                                                                                                                                |
| -- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Q1 | Does the `SCStream` audio tap work for unsigned `swift build -c release` binaries, or do we need ad-hoc codesigning?                                                                         | Victor | 2026-05-15 | Open                                                                                                                                                                  |
| Q2 | Does `SortformerDiarizer` actually meet its 480 ms latency claim on M4 Pro Tahoe, or does it backpressure on the buffer queue?                                                               | Victor | 2026-05-16 | Open                                                                                                                                                                  |
| Q3 | What's the right way to express "speaker 2" in `finals.md` while keeping the file diff-friendly when reprocessing? `[S2]` prefix or YAML frontmatter per line?                               | Victor | 2026-05-15 | **Resolved:** `[S<N>]` inline prefix, no frontmatter; keeps grep/jq-friendly and Obsidian-readable.                                                                   |
| Q4 | Should `chronicle merge` also produce a unified JSONL trace, or just the markdown?                                                                                                           | Victor | 2026-05-17 | Open                                                                                                                                                                  |
| Q5 | If Foundation Models live tagging trips the unsafe-content guardrail repeatedly on a transcript, should we degrade to keyword extraction via `NaturalLanguage` instead of silently dropping? | Victor | 2026-05-18 | Open                                                                                                                                                                  |
| Q6 | Should the rotation timer be a wall-clock deadline or a per-segment audio-duration accumulator? Audio duration is more accurate; wall-clock is simpler.                                      | Victor | 2026-05-15 | **Resolved:** Audio-duration accumulator. Wall-clock drifts if the engine briefly stalls; audio duration is what `AVAudioFile.length / sampleRate` gives us directly. |

---

## 13. Related

| Issue                                                                                                    | Relationship                                                                                            |
| -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| [`docs/adr/ADR-0001-modular-pipeline-architecture.md`](../adr/ADR-0001-modular-pipeline-architecture.md) | structural ADR; constrains every FR in this PRD                                                         |
| [`docs/adr/ADR-0002-audio-storage-format.md`](../adr/ADR-0002-audio-storage-format.md)                   | codec/container ADR for FR-1 — default Opus-in-CAF (amended 2026-05-13) + raw-PCM scratch + ALAC export |
| [`docs/adr/ADR-0003-locale-resolution-policy.md`](../adr/ADR-0003-locale-resolution-policy.md)           | locale-policy ADR for FR-6 — candidate-set restriction + 4-knob hysteresis                              |
| chronicle-tool 0.1.0 (current spike state)                                                               | this PRD extends                                                                                        |
| `chronicle/notes/research-notes.md` Tahoe surface map                                                    | this PRD operationalises                                                                                |
| Future PRD: chronicle storage tiers                                                                      | depends on this PRD's segmented audio output                                                            |
| Future PRD: chronicle agent / search layer                                                               | enabled by this PRD's resilient trace JSONL                                                             |

---

## 14. Changelog

| Date       | Change        | Author                                   |
| ---------- | ------------- | ---------------------------------------- |
| 2026-05-13 | Initial draft | Victor (drafted via the chronicle agent) |

---

## 15. Verification (Appendix)

After implementation, run these manual checks against a real session:

1. Launch `chronicle mic --locale pt-BR --diarize --tag-every 3 --rotate-audio 60 --live live.md --append finals.md --save-audio audio/session.wav -o trace.jsonl` for 5 minutes; speak with at least 2 voices.
2. Verify `audio/` contains 5+ valid WAV segments; concatenate via `ffmpeg -f concat` and re-transcribe with offline `chronicle transcribe`; verify the result matches `finals.md`.
3. Kill -9 the daemon mid-stream; verify the trailing audio segment is malformed; run `chronicle repair` on it; verify it now plays in `afplay`.
4. Inspect `finals.md`: every line is prefixed with `[S<N>]`; speaker labels are stable across the session.
5. Inspect `tags.jsonl`: one entry per `--tag-every` interval; each entry's `topics` array is non-empty and grounded in the surrounding transcript window.
6. Launch a second daemon `chronicle sysaudio --locale en-US --diarize --live live-sys.md --append finals-sys.md --save-audio audio-sys/session.wav -o trace-sys.jsonl` in parallel; play a YouTube video; verify both daemons run side-by-side under 5% combined CPU.
7. Run `chronicle merge finals.md finals-sys.md > merged.md`; verify chronological order, source prefixes preserved, speaker labels preserved.
8. Compare resource usage in `htop` to the NFR ceiling (≤ 5% CPU, ≤ 200 MB RSS combined).
