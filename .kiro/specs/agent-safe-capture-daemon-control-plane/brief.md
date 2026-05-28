# Brief: agent-safe-capture-daemon-control-plane

## Problem

Chronicle can now run proven live sysaudio capture with progressive diarization,
but the control model is still process-oriented: an operator or agent starts a
long-running `chronicle sysaudio` command and tails files. Multiple agents can
accidentally spawn duplicate physical capture processes, compete for CoreAudio
taps, parse stderr instead of state, or lose continuity during retries and
crashes.

The operator needs 24/7 capture that agents can control safely without touching
physical audio sources directly.

## Current State

- Direct sysaudio capture works through `/Applications/chronicle.app` with Team
  ID `CXLYTY8DMR` and CoreAudio process taps.
- Direct-mode rollback is tagged as
  `baseline-sysaudio-diarize-live-2026-05-28`.
- `scripts/smoke-sysaudio-diarize.sh` proves the current baseline with
  `fnox get ELEVENLABS_API_KEY`, ElevenLabs `eleven_v3` generated
  Sarah/George/Charlie/Alice fixtures, nonzero `sessionPeak`, no `--quiet`
  stdout spam, four transcript markers, and at least three marker speakers.
- `trace.jsonl`, `finals.md`, `live.md`, ALAC CAF segments, and raw PCM scratch
  are already durable sidecar surfaces.
- Existing Kiro spec `sysaudio-runtime-hardening` covers advisory TCC messaging,
  output rebuild debounce, and diagnostic verbosity. It does not own daemon/RPC
  control-plane work.
- `docs/prd/PRD-003-agent-safe-capture-daemon-control-plane.md` now captures the
  high-level PRD for this feature.

## Desired Outcome

Chronicle has one daemon owner per physical source (`sysaudio`, `mic`) and many
safe clients. Agents use a self-describing local JSON-RPC API and append-only
JSONL streams for status, subscribe, mark, clip, stop/start, and hot
reconfigure. Mutating operations are retry-safe, capture remains live during
progressive quality-layer prewarm, and `kill -9` recovery is a required test
gate before the feature is considered implemented.

## Approach

Build a daemon control plane in small, testable slices:

1. Add source ownership first: PID file + `flock`, daemon epoch, manifest/control
   JSONL, and kill/restart recovery tests.
2. Add a Unix-domain JSON-RPC server/client with `meta.schema` and `status.get`
   before mutating controls.
3. Wrap the existing direct `mic`/`sysaudio` pipelines rather than rewriting
   CoreAudio or SpeechAnalyzer internals.
4. Add idempotency keys, TTL leases, and `events.subscribe` before higher-level
   commands such as `mark`, `clip`, and hot reconfigure.
5. Preserve direct `mic`/`sysaudio` mode as the rollback escape hatch until P12
   smoke gates pass repeatedly.

This is one new spec boundary because all pieces share the same invariant:
**safe agent control of a single physical capture owner without regressing the
current live transcript path**.

## Scope

- **In**:
  - `chronicle daemon run --source sysaudio|mic`
  - source-owner PID/`flock` gate
  - daemon epoch + manifest/control JSONL
  - Unix socket path convention
  - JSON-RPC 2.0 protocol and typed structured errors
  - `meta.schema` OpenRPC-style discovery
  - `status.get`
  - thin CLI clients: `start`, `stop`, `status`, `tail`, `mark`, `clip`, `config`
  - idempotency via `client_req_id`
  - TTL leases for multi-step client operations
  - server-side `events.subscribe` filtering
  - hot reconfigure safety gates for supported settings
  - heartbeats and stale-daemon detection
  - kill -9 crash recovery smoke/test gate
- **Out**:
  - replacing CoreAudio taps or changing the current system-audio backend
  - cloud transcription or production ElevenLabs use
  - remote network API or token auth
  - gRPC
  - retention/pruning/storage-tier policy
  - speaker identity memory beyond preserving speaker labels in events
  - launchd/login-item packaging beyond daemon compatibility

## Boundary Candidates

- **Source ownership**: owns PID/lock/epoch/resource exclusivity before hardware
  opens.
- **RPC protocol**: owns JSON-RPC envelopes, method schemas, typed errors,
  idempotency, and Unix-socket client/server plumbing.
- **Event durability**: owns manifest/control/trace JSONL v1 envelopes,
  sequence, wall/monotonic clocks, recovery, and heartbeats.
- **Capture session wrapper**: adapts existing `Mic`/`SysAudio` pipelines into
  daemon-managed sessions without changing the hot audio path first.
- **Agent CLI UX**: thin commands only; business logic stays in daemon/RPC layer.

## Out of Boundary

- Do not mix mic and sysaudio into one raw analyzer stream.
- Do not make private TCC preflight the authority for capture health.
- Do not block rough transcript output on Sortformer, tagging, summarization, or
  other quality-layer prewarm.
- Do not let any agent client hold an indefinite lock; client coordination uses
  TTL leases.
- Do not remove direct `sysaudio` / `mic` rollback mode while the daemon is still
  new.

## Upstream / Downstream

- **Upstream**:
  - `sysaudio-runtime-hardening` Kiro spec, already implemented, for the stable
    CoreAudio runtime baseline.
  - `docs/prd/PRD-001-resilient-multi-source-daemon.md` for existing sidecar,
    trace, diarization, and crash-resilience contracts.
  - `docs/prd/PRD-003-agent-safe-capture-daemon-control-plane.md` for the PRD
    source material.
  - `Sources/Chronicle/Subcommands/Mic.swift` and `SysAudio.swift` as direct
    pipeline owners to refactor behind daemon mode.
  - `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift`,
    `AtomicFile.swift`, `SessionOutputPaths.swift`, `SignalHandler.swift`, and
    `MonotonicClock.swift` for existing durability/runtime primitives.
- **Downstream**:
  - live tagging and summarization clients
  - speaker identity memory (`PRD-002`)
  - Obsidian/vault ingestion watchers
  - launchd/login-item packaging
  - retention/storage-tier policy
  - future agent workflows that need `status`, `subscribe`, `mark`, and `clip`

## Existing Spec Touchpoints

- **Extends**: none. `sysaudio-runtime-hardening` is adjacent and already
  implemented; daemon control is a new boundary.
- **Adjacent**:
  - `.kiro/specs/sysaudio-runtime-hardening`
  - `docs/prd/PRD-001-resilient-multi-source-daemon.md`
  - `docs/prd/PRD-002-speaker-identity-memory.md`
  - `docs/prd/PRD-003-agent-safe-capture-daemon-control-plane.md`

## Constraints

- macOS 26 Tahoe and Apple Silicon only.
- Live capture must run through the signed `/Applications/chronicle.app` path
  when TCC identity matters.
- Socket is local-only: `$XDG_RUNTIME_DIR/chronicle/{source}.sock`, falling back
  to a per-user mode-0700 temp runtime dir when absent.
- Every JSONL line must carry schema version, source, daemon epoch, sequence,
  monotonic time, and wall clock.
- Mutating RPCs require `client_req_id` and must be idempotent under retry.
- Slow subscribers and disk pressure must degrade explicitly without blocking
  capture indefinitely.
- Verification must include `swift test`, the existing generated-voice direct
  smoke, duplicate-owner checks, subscribe checks, hot-reconfigure checks, and a
  kill -9 recovery gate.
