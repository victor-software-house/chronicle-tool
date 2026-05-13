---
title: "Modular pipeline architecture for the chronicle daemon"
adr: ADR-0001
status: Proposed
date: 2026-05-13
prd: "PRD-001-resilient-multi-source-daemon"
decision: "Protocol-oriented core with subcommands as thin CLI veneers"
---

# ADR-0001: Modular pipeline architecture for the chronicle daemon

## Status

Proposed

## Date

2026-05-13

## Requirement Source

- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md`
- **Decision Point**: §8 D4 (in-process fan-out) and §9 File Breakdown — the
  PRD calls for sharing buffer streams, sidecar surfaces, and reusable
  Foundation Models helpers across `mic`, `sysaudio`, `live`, and several
  new subcommands. This ADR formalises *how* that sharing is structured.

## Context

The current `chronicle-tool` codebase has each subcommand as a standalone
Swift file under `Sources/Chronicle/` (e.g. `Mic.swift`, `Live.swift`,
`Tag.swift`). Each file wires audio source → analyzer → sinks inline. That
was the right shape for a 10-subcommand spike; it is the wrong shape for
PRD-001, which adds:

- Two audio sources (`AVAudioEngine` mic + `SCStream` system audio) feeding
  the same analyzer pipeline.
- Two diarizer modes (offline VBx + streaming Sortformer) feeding the same
  finals path.
- Five distinct sinks per session (`live.md`, `finals.md`, `tags.jsonl`,
  `trace.jsonl`, `audio/session-*.wav`) consuming the same event stream.
- A live tagger that calls the same FoundationModels API the standalone
  `tag` and `summarize` subcommands already use.

Without a shared structure, PRD-001's implementation would either:

- duplicate the mic pipeline inside `SysAudio.swift` (drift risk, two
  files to keep in sync as Apple's `Speech` framework evolves), or
- collapse everything into one bloated `Mic.swift` with `if-`s on the
  source type (unreadable past ~500 LOC).

The Tahoe / Apple-Silicon integration **also** constrains us:

- `installTap` callback runs on the audio thread. Cannot await, cannot
  allocate heavily, cannot block.
- `AVAudioPCMBuffer` is a class (reference semantics) — passing it to
  multiple consumers is free, *as long as consumers read-only*.
- `SpeechAnalyzer.start(inputSequence:)` wants exactly one
  `AsyncStream<AnalyzerInput>` — feeding it from multiple producers needs
  a fan-in helper; feeding multiple consumers off the same audio needs a
  fan-out helper.
- Foundation Models `LanguageModelSession` has prewarm cost (~hundreds of
  ms first call). Repeated short calls benefit from caching the session
  per-model.

So modularity has to respect: audio-thread sync constraints, zero-copy
buffer sharing, single-stream-per-analyzer API, and session reuse.

## Decision Drivers

- **PRD-001 NFR latency budget**: volatile updates ≤ 200 ms, full stack
  ≤ 5 % CPU, ≤ 200 MB RSS. Any abstraction must cost essentially zero in
  the hot path.
- **PRD-001 in-scope FRs span two audio sources** (mic + sysaudio), two
  diarizer modes (offline + streaming), and five sidecars — duplicating
  any of these is a drift bomb.
- **Testability**: the current code can only be tested by running the
  binary against real audio. PRD-001's resilience requirements (FR-1, FR-2,
  FR-8) demand crash-recovery tests, which require mockable seams.
- **Apple framework ergonomics**: Swift 6 protocols devirtualize most
  calls inline; existential dispatch costs ~10 ns per indirect call, which
  is dwarfed by `AVAudioConverter` (~50 µs/buffer). Modularity at protocol
  boundaries is essentially free.
- **Spike-to-product transition**: this codebase is moving from a
  10-subcommand spike to a long-running chronicle service. The shape we
  pick now constrains every future subcommand.

## Considered Options

### Option 1: Keep the flat-file structure; extend each subcommand inline

Keep `Sources/Chronicle/Mic.swift`, add `SysAudio.swift` next to it, copy
the relevant pieces. Add `--diarize`, `--tag-every`, `--rotate-audio` etc.
as conditional branches inside the existing `run()` method.

- Good, because no refactor cost; PRD-001 FRs land as direct edits to
  existing files.
- Good, because Swift compile time stays fast (≤ 4 s incremental).
- Bad, because `Mic.swift` is already 350 LOC; adding PRD-001 takes it
  past 700 with overlapping concerns.
- Bad, because `SysAudio.swift` would duplicate ~80 % of `Mic.swift`,
  guaranteed to drift as Apple's APIs change.
- Bad, because each new sidecar (`tags.jsonl`, rotated WAV) requires an
  inline block of file-I/O code in every subcommand that needs it.
- Bad, because **the audio tap, file writers, and analyzer plumbing
  cannot be unit-tested** — only validated end-to-end against real
  hardware. PRD-001's crash-recovery requirements make this expensive.
- Bad, because future audio sources (network RTSP, file replay,
  Bluetooth) each require a new copy of the orchestration code.

### Option 2: Single monolithic `chronicled` daemon binary

Collapse all subcommands into one long-running daemon (`chronicled`) that
configures itself via a YAML/JSON config and runs every pipeline
internally. Subcommands become CLI verbs that send messages to a running
daemon.

- Good, because session caching (Foundation Models, model assets) happens
  exactly once.
- Bad, because it forces an IPC layer (Unix socket / XPC) for tooling that
  is currently happily standalone (`chronicle transcribe foo.wav` is
  perfect as-is).
- Bad, because crash blast-radius increases — one daemon dying kills
  every stream.
- Bad, because operator UX gets worse: every command requires the daemon
  to be running.
- Bad, because the PRD's resilience model assumes per-process scope; one
  daemon contradicts the segmented-recovery story.

### Option 3: Protocol-oriented core; subcommands as thin CLI veneers

Refactor into a layered structure:

```text
Sources/Chronicle/
├── Chronicle.swift                  # CLI dispatch
├── Subcommands/                     # one file per CLI verb, thin (~60 LOC each)
│   ├── Mic.swift / SysAudio.swift / Transcribe.swift / Live.swift
│   ├── Tag.swift / Summarize.swift / Describe.swift / Translate.swift / OCR.swift
│   └── Merge.swift / Repair.swift
├── Core/Audio/                      # protocols + impls
│   ├── AudioSource.swift            # protocol: yields AnalyzerInput + raw PCM
│   ├── MicAudioSource.swift         # AVAudioEngine impl
│   ├── SysAudioSource.swift         # SCStream impl
│   ├── FileAudioSource.swift        # AVAudioFile impl
│   ├── BufferMulticast.swift        # fan-out (sync, lock-free)
│   └── BufferConverter.swift        # AVAudioConverter wrapper
├── Core/Speech/
│   ├── TranscriptionEngine.swift    # SpeechAnalyzer wrapper, preset-agnostic
│   └── LocaleResolver.swift         # NLLanguageRecognizer auto-detect
├── Core/Diarize/
│   ├── Diarizer.swift               # protocol
│   ├── OfflineDiarizer.swift        # FluidAudio OfflineDiarizerManager
│   └── StreamingDiarizer.swift      # FluidAudio SortformerDiarizer
├── Core/LLM/
│   ├── ModelHost.swift              # cached LanguageModelSession
│   ├── ContentTagger.swift          # @Generable + tagText()
│   ├── Summarizer.swift             # @Generable + summarizeText()
│   └── ImageDescriber.swift         # Vision multi-request + FM narration
├── Core/Sinks/                      # transcript / audio event consumers
│   ├── TranscriptionSink.swift      # protocol: didReceive(volatile|final)
│   ├── LiveFileSink.swift           # atomic-rewrite live.md
│   ├── FinalsAppendSink.swift       # append-per-final
│   ├── JSONLTraceSink.swift         # incremental trace
│   ├── TagsJSONLSink.swift          # tags every N finals
│   └── WAVSegmentSink.swift         # rotating WAV writer
├── Core/Runtime/
│   ├── SignalHandler.swift          # SIGINT/SIGTERM OneShotResume
│   ├── AtomicFile.swift             # atomic-write + JSONL primitives
│   └── LivePipeline.swift           # orchestrator
└── Info.plist
```

Each subcommand collapses to a ~60-line orchestration of protocols.
Implementations behind the protocols are concrete and free to use Apple
APIs directly.

- Good, because adding a new audio source (network RTSP, Bluetooth, file
  replay) = one new `AudioSource` impl + zero changes elsewhere.
- Good, because adding a new sidecar (SQLite WAL, MQTT publisher, Parquet
  log) = one new `TranscriptionSink` impl.
- Good, because each protocol becomes a unit-test seam (mock
  `AudioSource`, feed canned buffers, assert sink calls).
- Good, because the offline batch pipeline (`Transcribe.swift`) and the
  live pipeline share the same `TranscriptionEngine` + sink contracts.
- Good, because `FoundationModels` `LanguageModelSession` lives in
  `ModelHost` and is reused across `tag`, `summarize`, `describe`, and the
  live tagger — prewarm cost paid once per process.
- Good, because the audio hot path stays sync: `BufferMulticast` is a
  lock-free ring-buffer fan-out, consumers pull async on their own tasks.
- Good, because `AVAudioPCMBuffer` reference semantics mean fan-out is
  free (no copies).
- Bad, because the refactor itself is ~1 day of work and touches every
  subcommand file once.
- Bad, because protocol existentials add ~10 ns per indirect call
  (negligible vs the ~50 µs/buffer the converter already spends).
- Neutral: adds ~10 new files, but each is small and single-purpose; the
  flat structure already has 11 subcommand files of similar size.

## Decision

Chosen option: **"Protocol-oriented core with subcommands as thin CLI
veneers"** (Option 3), because it is the only option that satisfies all
of PRD-001's decision drivers simultaneously:

- The latency budget is preserved (protocol cost is negligible, hot path
  stays sync, buffers are shared by reference).
- The two-source / two-diarizer / five-sink fan-out becomes free of
  duplication — every new combination is composition, not copy-paste.
- Crash-recovery and rotation logic (FR-1, FR-2, FR-8) get a mockable
  seam (the sinks) without depending on real audio hardware.
- The offline batch path (`Transcribe`) and the live path (`Mic`,
  `SysAudio`) share a single `TranscriptionEngine` definition, so changes
  to Apple's `Speech` framework land in one place.
- Foundation Models session caching becomes natural via a single
  `ModelHost`, rather than scattered `LanguageModelSession(...)`
  instantiations.

Option 1 (flat) was rejected because PRD-001's surface area pushes
`Mic.swift` past 700 LOC and forces ~80 % duplication into `SysAudio.swift`.
Option 2 (monolithic daemon) was rejected because chronicle benefits from
per-process scope for crash blast-radius containment and operator UX is
worse with a required daemon.

## Consequences

### Positive

- New audio sources require one file (`<Name>AudioSource.swift`); the
  rest of the system inherits them.
- New sinks require one file (`<Name>Sink.swift`); compose with `.append`
  into any pipeline.
- Each protocol is a natural unit-test boundary: mock the protocol, feed
  scripted inputs, assert outputs.
- `LanguageModelSession` is created once per process via `ModelHost`,
  amortising prewarm across `tag`, `summarize`, and the live tagger.
- The future "chronicle as a service" architecture (out-of-process
  consumers via Unix sockets / XPC) becomes a `RemoteSink` impl on the
  same protocol — no architectural change required.

### Negative

- One-time refactor cost (~1 day to migrate the existing subcommands,
  build tests, validate behaviour parity). Mitigated by doing it as the
  first step of PRD-001 P0; the work pays for itself before P5
  (diarization) lands.
- Protocol existentials cost ~10 ns per indirect call. Mitigated by using
  generics (`<S: AudioSource>`) where compile-time specialisation matters
  and existentials where it doesn't. Negligible vs the ~50 µs/buffer
  converter and ~150 ms volatile cadence.
- More files in the source tree (~10 net new). Mitigated by clear
  `Core/<area>/` subdirectories — better than 5 monolithic files of 500
  LOC each.
- The hot-path `BufferMulticast` is the only piece that absolutely cannot
  use locks or actor isolation — needs a hand-rolled SPMC ring buffer per
  consumer. Documented and unit-tested as such.

### Neutral

- Existing 10 subcommands continue to work during the refactor (we move
  the inline code into Core piece-by-piece and the subcommand becomes a
  thinner wrapper each step).
- The PRD-001 file breakdown is rewritten to use the new structure — see
  §9 of the PRD.
- This ADR does not pin a specific testing framework. Swift Testing
  (`@Test`) is the default choice for new code; XCTest is acceptable for
  pieces that need older tooling. To be decided in a follow-up ADR if it
  becomes contentious.

## Related

- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md`
- **Plan**: (none yet — this ADR + the PRD's rollout plan are sufficient
  for now; promote to a plan doc if more than 2 contributors need to
  coordinate)
- **ADRs**: foundational ADR; no supersession or relation to prior ADRs
  in this repo (this is the first).
- **Implementation**: P0 refactor task (added to the chronicle task list
  2026-05-13).
