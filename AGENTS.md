# chronicle-tool · agent operational guide

Cold-start guidance for agents (and humans) working in this repo. Refines
the global Pi agent baseline; does not duplicate it.

## What this repo is

Single Swift 6 executable (`chronicle`) packaging eleven on-device ML
subcommands on Apple Silicon Tahoe (macOS 26). Spike phase is complete;
work is now in **production spec phase** governed by the PRD + ADRs
under [`docs/`](docs/). Read those before changing behaviour.

Authoritative reading order for any non-trivial change:

1. [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](docs/prd/PRD-001-resilient-multi-source-daemon.md) — master PRD (FRs, NFRs, rollout, verification appendix).
2. [`docs/adr/ADR-0001-modular-pipeline-architecture.md`](docs/adr/ADR-0001-modular-pipeline-architecture.md) — protocol-oriented `Core/` + `Subcommands/`. **Implemented (P0).**
3. [`docs/adr/ADR-0002-audio-storage-format.md`](docs/adr/ADR-0002-audio-storage-format.md) — Opus 24 kbps in CAF as default (amended 2026-05-13 from Ogg); raw-PCM scratch; ALAC export; `.opus` Ogg via on-demand ffmpeg rewrap. **In progress (P11).**
4. [`docs/adr/ADR-0003-locale-resolution-policy.md`](docs/adr/ADR-0003-locale-resolution-policy.md) — candidate-set restriction + 4-knob hysteresis. **Pending (P4).**
5. [`docs/STATUS.md`](docs/STATUS.md) — quick-reference roadmap: every phase + current task state in one screen.
6. [`README.md`](README.md) — operator quick-start, subcommand surface, architecture diagram.
7. [`spikes/`](spikes/) — pre-refactor receipts. Treat as historical evidence; source-code layout in spike docs predates ADR-0001.

If the user just asks "what's next?", point them at `docs/STATUS.md` and
the open tasks in the Pi task graph.

## Repo shape (post-P0 modular refactor)

```text
Sources/Chronicle/
├── Chronicle.swift           @main + ArgumentParser dispatch
├── Subcommands/              thin CLI veneers (one per `chronicle <verb>`)
└── Core/
    ├── Audio/                AudioSource protocol + MicAudioSource + SysAudioSource + BufferConverter
    ├── Speech/               TranscriptionEngine (SpeechAnalyzer factory)
    ├── Diarize/              OfflineDiarizing protocol + FluidAudio impl
    ├── LLM/                  cached LanguageModelSession (ModelHost) + ContentTagger + Summarizer
    ├── Sinks/                TranscriptionSink protocol + LiveFileSink + FinalsAppendSink
    └── Runtime/              SignalHandler (SIGINT/SIGTERM) + AtomicFile (atomic-write / append-line)
Tests/ChronicleTests/         Swift Testing (`@Test`). Per-module tests land per FR.
docs/{prd,adr}/               specdocs artefacts (validated via specdocs_validate).
spikes/                       2026-05-13 spike receipts (historical).
```

Hard rules for changes:

- **New audio source** → add one file under `Core/Audio/` conforming to `AudioSource`. Do not duplicate engine / tap / converter wiring inside a subcommand.
- **New sidecar** → add one file under `Core/Sinks/` conforming to `TranscriptionSink`. Compose into the pipeline via `sinks.append(…)`; do not inline file I/O in subcommands.
- **New LLM consumer** → reuse `ModelHost.shared.session(for:instructions:)`. Never instantiate `LanguageModelSession` directly — the prewarm tax is paid once per `(useCase, instructions)` pair.
- **New diarizer mode** → add an impl behind `OfflineDiarizing` or `StreamingDiarizing` (FR-4 will introduce the latter). Use `DiarizationSegment` + `DiarizationResult` as the wire format.
- **New subcommand** → file lives in `Subcommands/`, ~60 LOC max, orchestrates `Core/` protocols. Add to `Chronicle.swift` dispatch list.

## Build, test, smoke

```sh
swift build                       # debug
swift build -c release            # release for daemon use
swift test                        # Swift Testing target (ChronicleTests)
.build/debug/chronicle --help     # subcommand surface
```

`Package.swift` embeds `Info.plist` via `-sectcreate -Xlinker __info_plist`
so the binary carries the TCC strings (`NSMicrophoneUsageDescription`,
`NSSpeechRecognitionUsageDescription`, `NSScreenCaptureUsageDescription`).
Do not remove the `unsafeFlags` linker block.

### Production: build the `.app` bundle (REQUIRED for `mic` / `sysaudio`)

The bare `swift build` artefact has the Info.plist embedded in `__TEXT
__info_plist` but `codesign -dvv` reports `Info.plist=not bound` — which
causes `SCStream` to silently deliver placeholder buffers with garbage
ASBDs when audio capture is attempted (macOS Sequoia/Tahoe attributes
audio TCC to a stable bundle identity, and the bare binary doesn't
have one).

```sh
scripts/make-app.sh              # builds .build/release/chronicle.app, adhoc-signs it
```

The bundle has bundle ID `com.victor-software-house.chronicle`. **First
run requires the operator to grant TCC to this bundle** (one-time):

1. Build the bundle: `scripts/make-app.sh`
2. System Settings → Privacy & Security → Screen & System Audio
   Recording → `+` → add `.build/release/chronicle.app`
3. (For `chronicle mic`) Same flow under Privacy & Security → Microphone.
4. Run via the bundle path:
   ```sh
   .build/release/chronicle.app/Contents/MacOS/chronicle sysaudio ...
   ```

Without the grant, `chronicle sysaudio` fails fast in ~5 s with a clear
`audioCaptureSilent` error pointing back to this section — it does
**not** hang.

### Robustness layer (Core/Audio/TCCPreflight + Core/Runtime/AsyncTimeout)

Three defensive layers around the live audio pipeline; do not remove
without replacing:

| Layer | Defense |
|---|---|
| **L1.** `TCCPreflight.screenRecording()` / `.microphone()` | Non-blocking TCC check before any blocking system audio call. Fails fast with actionable remediation. |
| **L2.** `SysAudioSource.start()` first-valid-buffer watchdog (5 s) | Catches the case where preflight passed but SCStream silently delivers garbage-ASBD placeholder buffers (audio TCC denied for the binary identity). Throws `audioCaptureSilent`. |
| **L3.** Bounded `analyzer.finalizeAndFinishThroughEndOfInput()` (5 s + 2 s) | If the analyzer received only degenerate input, finalize would otherwise hang; we time out and fall through to `cancelAndFinishNow`. |

Verification expectations:

- Every refactor that touches a hot path must reproduce **byte-identical**
  `transcribe.txt` + `diarize.json` segments against the 2026-05-13 Zoom
  reference (`mic-master.wav`, 6870 s, 56 transcribe segments, 91 diarize
  segments, 5 speakers). This is the P0 parity contract; any FR
  implementation that drifts must justify the drift in its PRD acceptance
  criteria.
- Live subcommands (`mic`, `sysaudio`) require a real audio source for
  end-to-end verification. The harness convention is: start the capture
  via the Pi `process` tool, then start a TTS / playback as a second
  process so they overlap. Tail `finals.md` for evidence.

## TCC + signing realities

This binary is unsigned during dev. macOS attributes TCC requests to the
**parent process** in the responsibility chain (the terminal / cmux /
launcher / etc.). Implications:

- `mic` (Microphone): grant once at the parent terminal/cmux app. The
  Info.plist string surfaces on first run.
- `sysaudio` (Screen Recording): same model — grant cmux.app or
  Terminal.app, not chronicle directly. If buffers come back silent and
  `--verbose` shows zero peak, TCC is the cause **even if `start()`
  returned without throwing**. SCStream silently produces zero buffers
  when permission is missing.

Future signed-bundle work (`chronicle.app` with stable
`CFBundleIdentifier`) will give chronicle its own TCC identity. Not
blocking; document the friction when it bites.

## Parity reference data

The 2026-05-13 Zoom session is the canonical reference:

| Path | Purpose |
|---|---|
| `~/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/mic-master.wav` | 6870 s, 16 kHz Int16 mono — the input |
| `out/full-session/transcribe.txt` | 3680-char reference transcript (byte-compare target) |
| `out/full-session/diarize.json` | 91 segments / 5 speakers reference |
| `spikes/2026-05-13-daemon-live-mic.md` | live-mic spike receipts (historical) |

`out/` is gitignored. The data lives locally and is **not source of
truth**; the PRD + ADRs are. Do not regenerate it during a refactor — the
parity test compares post-refactor output against the committed-elsewhere
receipts.

## Commit style

- Conventional Commits. Common scopes: `p0/*` (refactor phases),
  `sysaudio`, `adr`, `prd`, `readme`, `tests`.
- Small, frequent commits at logical checkpoints. Build green at every
  commit. Smoke-test that the touched subcommand still runs.
- No AI-attribution trailers, no "generated with" footers (per the
  machine-global policy in `~/AGENTS.md`).
- For non-trivial changes, follow the rollout order in PRD-001 §11 unless
  there's an explicit reason to reorder (record the reason in the commit
  body and update the PRD).

## When to load which skill

| Trigger | Skill |
|---|---|
| New PRD / FR / acceptance criteria | `prd` |
| Architectural decision worth recording | `adr` |
| Multi-phase implementation plan from a PRD | `plan-prd` |
| Validating spec doc structure | `specdocs_validate` |
| Inspecting prior session decisions / logs | `session-inspect` |
| Pi-specific harness questions | the Pi skills under `~/.pi/agent/skills/` |

## Where the broader chronicle context lives

- `../notes/` — research-chronicle repo: Tahoe surface map, retention
  tiers, cost model, design history. Read `research-notes.md` for the
  "why" behind the project; this repo for the "how".
- `../fluidaudio/`, `../swift-scribe/`, `../ora/`, etc. — sibling
  reference codebases evaluated during the spike. Treat as evidence, not
  upstreams.

## What good progress looks like in this repo

1. Pick the next open PRD-001 phase from `docs/STATUS.md`.
2. Update the corresponding task to `in_progress` via `TaskWrite`.
3. Land code + tests in the smallest commit that's still green.
4. If the change touches an FR's acceptance criteria, update PRD-001
   inline. If the decision is durable, write an ADR before the code.
5. Smoke-test on real audio (live subcommands) or the 2026-05-13
   reference (offline subcommands).
6. Mark the task `completed` with the receipt summary in the task
   metadata.
7. Commit + push. Both the chronicle-tool repo and (if relevant) the
   research-chronicle notes repo.

Anti-patterns:

- Inlining engine wiring, file I/O, or LLM-session construction inside a
  subcommand instead of going through `Core/`. The whole point of
  ADR-0001 is that subcommands are veneers.
- Adding a new audio sidecar by `try? someURL.write(…)` inside the
  consume loop. Use `TranscriptionSink`.
- Renaming `out/full-session/*` receipts to "update" parity numbers. The
  receipts are immutable historical evidence; if your code changed
  behaviour, justify it in the PRD or fix the regression.
- Removing `--verbose` flag plumbing from `SysAudioSource`. It's the
  only way to diagnose silent captures.
