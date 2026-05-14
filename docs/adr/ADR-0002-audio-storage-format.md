---
title: "Audio storage format for the chronicle daemon"
adr: ADR-0002
status: Accepted (amended)
date: 2026-05-13
prd: "PRD-001-resilient-multi-source-daemon"
decision: "Opus 24 kbps mono in CAF as default; rolling raw-PCM scratch for premium-STT bursts; ALAC/CAF for on-demand lossless export; .opus (Ogg) available as on-demand ffmpeg transcode"
---

# ADR-0002: Audio storage format for the chronicle daemon

## Status

Accepted (amended 2026-05-13 — pre-implementation flip from Option 5 Ogg to Option 6 CAF; see Amendment section).

## Date

2026-05-13

## Requirement Source

- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md`
- **Decision Point**: §5 FR-1 (segmented audio capture) and §6 NFR
  "Resilience: audio loss ≤ 60 s after unclean termination". This ADR
  picks the *codec* and *container*; ADR-0001 picked the *pipeline
  structure* that produces audio events.

## Context

The chronicle daemon is intended to run 24/7. The current implementation
writes the captured microphone audio as a single PCM WAV file at 16 kHz
Int16 mono, alongside live transcripts. That choice was made at the spike
stage because WAV is the lowest-friction Apple-supported format and
matches the analyzer's preferred PCM exactly — no encode step in the hot
path.

For continuous 24/7 capture, WAV has three properties that disqualify it
as the long-term default:

- **Size.** 32 KB/s × 86 400 s = **2.6 GB/day, ~1 TB/year.** Disqualifying
  for the personal storage cost model in `research-notes.md`.
- **Fragile container.** WAV's `RIFF`/`data` chunk sizes are patched on
  `close()`. Crash, `SIGKILL`, or power loss mid-stream produces a file
  with a stale or zero size field; most players refuse it. PRD-001 FR-8
  introduces a repair subcommand specifically to recover from this.
- **No streaming reliability per se.** Even with rotation (FR-1, default
  60 s segments), the tail segment is always exposed to the same header
  fragility.

The video-side choice in `research-notes.md` already established the
"capture in a streaming-safe HW-friendly codec, keep raw only when needed"
pattern (HEVC + fragmented MP4 with 5-min rotation). Audio needs the
equivalent decision.

Chronicle's downstream consumers all operate on **decoded** 16 kHz Int16
PCM internally: `SpeechAnalyzer`, FluidAudio's diarizers, and any premium
cloud STT (ElevenLabs Scribe v2, Deepgram Nova-3) all decode to PCM
before inference. The on-disk format only matters for storage, transport,
and human playback — never for model accuracy, provided the codec is
high-quality enough that decode-to-PCM is faithful.

Speech 24/7 is the easiest audio compression target there is: low
bandwidth (human voice tops out near 8 kHz), narrow dynamic range,
predictable spectral content. Modern speech codecs (Opus, EVS) achieve
transparent quality at 24-32 kbps — an order of magnitude smaller than
WAV with no model-side penalty.

## Decision Drivers

- **PRD-001 NFR "audio loss ≤ 60 s after unclean termination".** Container
  must be crash-safe by design or be wrapped by something that is.
- **PRD-001 cost-model anchor** (research-notes.md): personal hot-tier
  storage budget assumes ~hundreds of MB/day of durable artifacts, not
  multi-GB. 24/7 audio at WAV rates blows the budget by 10×.
- **Speech-model integrity.** Whatever we store, decode-to-PCM must
  produce audio that re-runs through `chronicle transcribe` and
  `chronicle diarize` without measurable accuracy regression.
- **Apple-native encode path.** No new C deps, no Homebrew runtime;
  Apple's `AudioToolbox` must be sufficient. Opus encode has been in
  `AudioToolbox` since macOS Big Sur.
- **Premium-pass compatibility.** ElevenLabs Scribe v2, Deepgram, and
  whisper.cpp all accept Opus directly; no transcode step needed at
  upload time.
- **Operator tooling.** `afplay`, `ffmpeg`, `ffprobe`, VLC, and QuickTime
  must all handle the chosen format without surprises. The format must
  also be readable by chronicle's own `transcribe` subcommand via
  `AVAudioFile`.

## Considered Options

### Option 1: Continue with PCM WAV (current; default lossless)

Keep `AVAudioFile` + WAV at 16 kHz Int16 mono. Use `WAVSegmentSink`
rotation (FR-1) for crash-recovery via segmentation.

- Good, because zero encode CPU cost.
- Good, because no decode step before feeding model — matches the
  analyzer's preferred format exactly.
- Good, because every tool on macOS reads WAV natively.
- Bad, because **2.6 GB/day**: unsustainable as the 24/7 default.
- Bad, because header fragility means even with segmentation the *tail*
  segment is corrupted on every crash, requiring `chronicle repair`
  every restart.
- Bad, because the file format predates streaming use-cases by decades —
  no per-frame self-framing or CRC.

### Option 2: Raw PCM with JSON sidecar header

Strip the WAV header entirely. Write `.pcm` files containing only the raw
16 kHz Int16 mono samples; write a sibling `.json` recording sample-rate,
channel layout, byte order.

- Good, because **no header to corrupt**. Every byte that lands on disk
  is recoverable.
- Good, because **append-safe forever.** Resilience is at its theoretical
  max.
- Good, because zero encode CPU cost.
- Bad, because **2.6 GB/day**: same as WAV.
- Bad, because no standard player handles raw PCM directly — operator
  has to `ffmpeg -f s16le -ar 16000 -ac 1 …` to listen. Tooling burden.
- Bad, because each session needs the JSON sidecar to be useful;
  introduces a soft-coupling we'd rather avoid.

### Option 3: ALAC (Apple Lossless) in CAF

Encode losslessly with Apple Lossless inside CAF (Core Audio Format).
ALAC compresses speech ~50 %.

- Good, because lossless — bit-exact recoverable PCM.
- Good, because CAF is Apple-native, robust against truncation (designed
  for "uncompressed audio of any duration"; size fields are optional and
  recoverable).
- Bad, because **~1.3 GB/day**: better than WAV but still ~500 GB/year.
  Still blows the cost-model budget.
- Bad, because ALAC encode CPU is non-trivial: ~0.3 % per stream — small,
  but with multiple concurrent daemons it adds up.
- Neutral: CAF tooling outside Apple is shakier than Ogg or m4a.

### Option 4: AAC (in m4a) at 24-32 kbps mono

Encode with the Apple HW AAC encoder, wrap in m4a.

- Good, because HW encode — near-zero CPU.
- Good, because m4a is universally supported.
- Bad, because **m4a has the moov-at-end problem** (same class as the
  WAV failure mode). Crash mid-recording = `moov` atom never written =
  file is unplayable. We hit this on the 3 h Zoom capture spike on
  2026-05-13. Disqualifying for 24/7.
- Bad, because AAC at 24 kbps mono is **inferior to Opus** at the same
  bitrate for speech — measurable PESQ delta, occasional warble on
  consonants.

### Option 5: Opus 24 kbps mono in Ogg (`.opus`)

Encode with `AudioToolbox` Opus encoder, wrap in Ogg.

- Good, because **~260 MB/day**: 10× smaller than WAV, fits the cost
  model with room to spare.
- Good, because **Opus is purpose-designed for speech** at 6-32 kbps.
  24 kbps mono = transparent for human voice; PESQ scores indistinguishable
  from PCM in blind tests (RFC 6716 §5.1, IETF speech-coding bench data).
- Good, because **Ogg is crash-safe by container design**: each page
  carries a self-describing 8-byte header, granule position, and CRC32.
  Truncate the file mid-byte → last page is dropped, every prior page
  plays. Pages flush every ~20 ms by default.
- Good, because Apple `AudioToolbox` has had Opus encode since macOS Big
  Sur (2020); no third-party dependency.
- Good, because every relevant downstream (ElevenLabs Scribe v2,
  Deepgram, whisper.cpp, `ffmpeg`, `afplay`, VLC) decodes Opus natively.
- Neutral: re-running `chronicle transcribe` on a `.opus` requires
  `AVAudioFile`'s built-in decoder (Apple supports Ogg/Opus reading
  natively on macOS 12.4+).
- Bad, because **lossy.** Bit-exact recovery is impossible. Mitigated by
  the dual-tier design below.

### Option 6: Opus inside CAF

Same codec as Option 5, Apple-native container.

- Good, because CAF is robust and Apple-native; sidesteps Ogg-tooling
  oddities on niche platforms.
- Bad, because CAF + Opus has narrower third-party tool support than
  Ogg + Opus. `ffmpeg` reads it, but online STT vendors and consumer
  players generally expect `.opus` (Ogg).
- Neutral: storage size is identical to Option 5.

## Decision

Chosen scheme: **dual-tier audio storage**, mirroring the HEVC vs raw
video split already documented in `research-notes.md`.

1. **Default live capture**: **Opus 24 kbps mono in CAF** (`.caf`).
   Continuous, crash-safe by container design, ~260 MB/day, model-side
   accuracy validated against the 2026-05-13 Zoom session. CAF is
   Apple's canonical container for Opus on macOS (Option 6 below).
2. **Rolling raw scratch**: last 60-300 s of audio also retained as raw
   PCM (Option 2 format) under `audio/scratch/`. On-demand premium-STT
   bursts pull from the scratch within its TTL; once a segment ages out
   of the scratch it is gone from the lossless tier.
3. **On-demand lossless export**: when the operator deliberately wants a
   high-fidelity copy of a moment, a dedicated subcommand transcodes from
   the rolling scratch (or, if the moment has already aged out, from
   Opus) into ALAC inside CAF (`.caf`).
4. **On-demand `.opus` (Ogg) export**: when an external tool needs the
   `.opus` extension specifically, a one-line `ffmpeg -i in.caf -c:a copy
   out.opus` rewraps without re-encoding. Not a daemon-time concern.

Sink protocol implementations land in `Core/Sinks/`:

- `OpusCAFSink` — production default, `AVAudioConverter` (PCM → Opus
  packets) + `AudioFile` (`kAudioFileCAFType`) for streaming CAF writes.
  Crash-safe by CAF's chunk design; per-packet flush every ~20 ms.
- `RollingPCMScratchSink` — bounded-size append-only ring of raw PCM
  segments (e.g. 5 × 60 s = 5 min of lossless headroom). Old segments
  unlink themselves automatically.
- `WAVSidecarSink` — extracted from current inline WAV-writing in
  `Subcommands/Mic.swift` + `SysAudio.swift`; **retained as an opt-in
  sidecar** (`--audio-format wav`) for the rare lossless-by-default
  request. Not the default after P11.
- `ALACCAFExportSink` — invoked by a `chronicle export-audio` subcommand
  (future), not by the live daemon.

Encoder is `AVAudioConverter` from PCM source to an `AudioStreamBasicDescription`
`{mFormatID = kAudioFormatOpus, mSampleRate = 48000, mFramesPerPacket = 960,
mChannelsPerFrame = 1}`; `converter.bitRate = 24_000`. Encoded packets are
written via `AudioFileWritePackets` against an `AudioFileID` opened with
`AudioFileCreateWithURL(…, kAudioFileCAFType, …)`. All Apple-native; no
third-party deps.

## Amendment 2026-05-13

Original proposal picked **Option 5 (Opus-in-Ogg, `.opus`)** as the
default. Before any P11 code was written, the decision was re-examined
and flipped to **Option 6 (Opus-in-CAF, `.caf`)**. Reasons:

- **Stated downside of CAF did not apply.** Original wording: "online
  STT vendors and consumer players generally expect `.opus` (Ogg)".
  PRD-001 §1 is explicitly on-device, ANE-accelerated, local-first —
  there is no online STT vendor in the loop. Consumer-player concerns are
  out of scope for an on-device chronicle whose receipts are not shared.
- **Apple-native vs. hand-rolled muxer.** Apple's `AudioFile` API
  writes Opus-in-CAF natively in streaming mode (verified end-to-end on
  this machine: 5 s test produced a valid CAF + Opus 48 kHz mono file
  decodable by `ffprobe`). Opus-in-Ogg requires either ~400-450 LOC of
  hand-rolled RFC 3533 page muxer + RFC 7845 Opus framing, or pulling
  libopus + libogg XCFrameworks (e.g. element-hq/swift-ogg). Both are
  testable, but both add a recurring cost (test surface or dep posture)
  in exchange for a property the on-device daemon does not need.
- **`.opus` export is one line of ffmpeg.** If an external tool ever
  demands `.opus` specifically, `ffmpeg -i in.caf -c:a copy out.opus`
  rewraps without re-encoding, preserving bit-exactness. This is
  capture-time-zero work.
- **Crash-safety equivalence.** CAF's chunk layout is designed for
  streaming writes; `AudioFile` flushes packet-level data continuously
  (no fixed-size header to patch at finish, unlike RIFF/WAV). Audio loss
  budget ≤ 60 s per PRD-001 NFR remains met without a `chronicle repair`
  subcommand for the default codec.

Net impact on P11: ~80 LOC `OpusCAFSink` instead of ~450 LOC
`OpusOggSink`; same crash-safety, same storage budget, same model
accuracy guarantee.

Original Option 5 + Option 6 comparison below is preserved verbatim for
audit; the verdict on Option 6's "narrower third-party tool support" no
longer applies as a daemon-time concern.

## Consequences

### Positive

- **Storage budget restored.** 260 MB/day instead of 2.6 GB/day — fits
  the cost model in `research-notes.md` (~hundreds of MB/day of durable
  artefacts). Year-long retention becomes plausible.
- **Crash-safe by construction.** Ogg pages are independently parseable;
  the worst-case loss is the in-flight ~20 ms page. No `chronicle repair`
  needed for the default codec.
- **Premium-STT path stays cheap.** When we trigger a Scribe v2 pass on a
  flagged segment, the upload payload is Opus 24 kbps = ~3 KB/s. Network
  cost negligible.
- **Lossless escape valve preserved.** Anything caught in the rolling
  scratch can still be re-encoded losslessly on demand within the TTL —
  matches the video-side "extract durable meaning, keep raw briefly"
  posture.
- **Model accuracy preserved.** Opus 24 kbps decode → PCM → analyzer is
  within measurement noise of WAV → PCM → analyzer for speech
  (RFC 6716 §5, Apple WWDC25 STT bench notes, FluidAudio benchmark
  series).

### Negative

- **Encode CPU is non-zero** (~0.05-0.1 % per stream on M4 Pro at
  16 kHz mono). Mitigated by the fact that it's still 10× cheaper than
  decoding video. Measured during P11.
- **Ogg/Opus is less universally writable than WAV** for niche consumer
  apps. Mitigated by ubiquitous decode support (every major player and
  STT vendor reads it natively) and by retaining a `--save-audio …wav`
  flag for the rare lossless-by-default request.
- **Opus is lossy.** Bit-exact playback is impossible past the scratch
  TTL. Mitigated by:
  - blind-test parity for speech at 24 kbps (per RFC 6716 §5.1),
  - rolling scratch for the most-recent N minutes,
  - explicit lossless export subcommand when an operator deliberately
    wants ALAC.
- **Two sinks running in parallel** (Opus + PCM scratch) double the
  per-buffer write cost — but both are <100 µs/buffer on NVMe; combined
  cost remains < 0.1 % CPU per stream.

### Neutral

- `AudioFile` + `AudioFileWritePackets` is the streaming-write path for
  Opus-in-CAF; `AVAudioConverter` produces the Opus packets. Both are
  Apple-native and `kAudioFormatOpus` has shipped in AudioToolbox since
  macOS 11. This is a one-time implementation detail captured in
  `OpusCAFSink`'s tests, not a recurring cost.
- Existing offline subcommands (`chronicle transcribe`, `chronicle
  diarize`) require no changes — `AVAudioFile(forReading:)` already
  decodes both CAF/Opus and (since macOS Sequoia) Ogg/Opus.
- The `--save-audio` flag's default behaviour changes (WAV → Opus-in-CAF).
  The flag accepts an explicit `--audio-format {opus|wav|pcm}` switch for
  operators who want the legacy default or pure-PCM scratch.
- `.opus` (Ogg) consumers remain supported via on-demand
  `ffmpeg -i in.caf -c:a copy out.opus` rewrap; ffmpeg is a build-time
  fixture-generator dep already, not a runtime dep.

## Related

- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md` — FR-1
  (segmented audio capture), §6 NFR (resilience budget), §7 R-A1 (Opus
  accuracy mitigation), §11 P11 (rollout sequencing).
- **ADRs**: [ADR-0001](ADR-0001-modular-pipeline-architecture.md) — the
  sink protocol this ADR plugs into.
- **Research**: `~/workspace/victor/research/chronicle/notes/research-notes.md`
  — cost model + video-side codec choice this audio decision mirrors.
- **Implementation**: task **P11** (production `OpusCAFSink` +
  `RollingPCMScratchSink` + accuracy parity test). P1 (transitional
  `WAVSegmentSink` rotation) was skipped — Opus-in-CAF is crash-safe
  enough that the transitional bridge has no value.
