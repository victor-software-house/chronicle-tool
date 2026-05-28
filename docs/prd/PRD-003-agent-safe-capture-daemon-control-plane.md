---
title: "Agent-safe capture daemon control plane"
prd: PRD-003
status: Draft
owner: "Victor"
issue: "N/A"
date: 2026-05-28
version: "0.1"
---

# PRD: Agent-safe capture daemon control plane

---

## 1. Problem & Context

Chronicle can now capture system audio through `/Applications/chronicle.app` with
CoreAudio taps, write rotating ALAC + scratch PCM sidecars, stream live/final
transcripts, and attach live Sortformer speaker labels as a progressive quality
layer. The current proof baseline is intentionally simple: the operator or Pi
starts one long-running `chronicle sysaudio --quiet --verbose --diarize ...`
process and tails sidecars.

That is not enough for the 24/7 target. Multiple agents may want to inspect,
start, stop, mark, clip, or reconfigure capture while the human is using the Mac.
If each agent spawns its own `sysaudio` or `mic` process, they duplicate physical
taps, compete during output-device rebuilds, and create confusing sidecar
surfaces. The safe model is one daemon per physical source, with many clients
controlling and consuming it through a small, retry-safe local API.

This PRD scopes the next layer: a local daemon control plane that preserves the
current live transcript contract while giving agents a robust interface for
24/7 capture, crash recovery, and safe live adjustment.

**Baseline preserved by this work:**

* rollback tag: `baseline-sysaudio-diarize-live-2026-05-28`
* current proven command: `/Applications/chronicle.app/Contents/MacOS/chronicle sysaudio --quiet --verbose --diarize ...`
* smoke guard: `scripts/smoke-sysaudio-diarize.sh` uses `fnox get ELEVENLABS_API_KEY`, ElevenLabs `eleven_v3`, and four generated voices to assert nonzero `sessionPeak`, no stdout spam, four transcript markers, and ≥3 marker speakers
* rough transcript starts immediately; diarization, tagging, summarization, and future speaker identity are progressive refinement layers

---

## 2. Goals & Success Metrics

| Goal                                 | Metric                                            | Target                                                                                                           |
| ------------------------------------ | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Single owner per physical source** | Concurrent daemon attempts for `mic` / `sysaudio` | Exactly one owner; duplicate starts return existing state or a retriable lease/resource error                    |
| **Agent-safe control**               | Mutating RPC retry behavior                       | Every mutation accepts `client_req_id` and is idempotent under retry                                             |
| **Crash-resilient event surface**    | JSONL validity after `kill -9`                    | All complete lines remain valid; at most one torn trailing line; next daemon resumes with a higher epoch         |
| **Low-latency transcript preserved** | Rough transcript startup                          | Capture starts before diarizer/tagger/model prewarm finishes                                                     |
| **Discoverable API**                 | Agent bootstrap steps                             | `meta.schema` returns OpenRPC/schema and examples without reading source files                                   |
| **Live consumer UX**                 | Event subscription latency                        | `subscribe` delivers filtered events within 250 ms of append under normal load                                   |
| **Safe reconfiguration**             | Settings changes                                  | Hot reconfigure applies supported knobs without restart; unsupported changes return structured errors with hints |

---

## 3. Users & Use Cases

### Primary: Chronicle operator

> As the operator, I want Chronicle to record microphone and system audio all day
> without worrying that an agent will accidentally start a second capture or lose
> the current session while changing settings.

### Primary: LLM / Pi agent client

> As an agent, I want a small self-describing API for status, subscribe, mark,
> clip, and reconfigure so I can help the operator without guessing paths,
> parsing noisy stderr, or touching physical audio sources directly.

### Secondary: launchd / process supervisor

> As a supervisor, I want a daemon that reports heartbeats, exits cleanly when
> asked, and recovers after `SIGKILL` or reboot without corrupting sidecars.

### Secondary: offline recovery tooling

> As a downstream processor, I want append-only manifests and JSONL events with
> schema versions, monotonic clocks, wall clocks, source IDs, and daemon epochs so
> that recordings can be rebuilt and audited after crashes.

---

## 4. Scope

### In scope

1. **Daemon subcommand** — `chronicle daemon run --source sysaudio|mic` owns one physical source and writes the same sidecars as the current live commands.
2. **Thin client commands** — `chronicle start`, `stop`, `status`, `tail`, `mark`, `clip`, and `config` talk to the daemon over the local socket; they do not open CoreAudio taps or microphones themselves.
3. **Unix-domain JSON-RPC 2.0** — local control socket under `$XDG_RUNTIME_DIR/chronicle/{source}.sock`, falling back to `/tmp/chronicle-$UID/{source}.sock` when the runtime dir is absent.
4. **Self-describing schema** — `meta.schema` returns an OpenRPC-style method list, request/response schemas, event schema, version, and examples.
5. **Append-only durable state** — `manifest.jsonl`, `trace.jsonl`, `control.jsonl`, and optional `tags.jsonl` carry schema version `v`, per-source sequence `seq`, daemon `epoch`, `t_mono`, and `t_wall` on every line.
6. **Lease-based source ownership** — PID + `flock` gate prevents double-daemon; client leases with TTL prevent orphaned long-running operations.
7. **Idempotent mutations** — mutating RPCs require `client_req_id`; daemon stores recent request results and returns the same response on retry.
8. **Subscribe RPC** — clients receive server-filtered events from trace/control streams without polling files.
9. **Hot reconfigure** — supported live settings update without restart; unsafe settings return a structured non-retriable error with a remediation hint.
10. **Crash recovery gate** — tests prove `kill -9` mid-recording leaves recoverable audio/JSONL and restart either resumes safely or refuses with a clear ownership error.

### Out of scope / later

| What                     | Why                                                                                            |
| ------------------------ | ---------------------------------------------------------------------------------------------- |
| Remote network API       | Local socket permissions are sufficient for now; no network exposure.                          |
| Token auth               | Socket path + filesystem permissions are the security boundary for the local operator machine. |
| gRPC                     | JSON-RPC + JSONL is easier for agents, jq, shell scripts, and Swift tests.                     |
| Schema registry service  | OpenRPC lives in tree and is returned by `meta.schema`.                                        |
| Cloud transcription      | Current privacy contract remains local-first; ElevenLabs is smoke-fixture generation only.     |
| Retention/pruning policy | Storage tiers need a separate PRD; this daemon only emits durable sidecars and metrics.        |

---

## 5. Functional Requirements

### FR-1: Source-owned daemon process

`chronicle daemon run --source sysaudio` and `chronicle daemon run --source mic`
start exactly one capture owner per physical source. A daemon owns the source by
holding an advisory lock file and publishing a PID/epoch record.

**Acceptance criteria:**

```gherkin
Given a sysaudio daemon is running
When a second sysaudio daemon starts
Then it fails before opening CoreAudio resources
And the error includes code "resource_busy", retriable=false, and the existing daemon PID/socket path
And the existing capture continues uninterrupted
```

```gherkin
Given a stale PID file exists for a dead daemon
When chronicle daemon run --source sysaudio starts
Then it verifies the PID is dead, acquires the flock, increments the daemon epoch, and starts capture
```

**Files:**

* `Sources/Chronicle/Subcommands/Daemon.swift` — `daemon run` entry point.
* `Sources/Chronicle/Core/Daemon/SourceOwner.swift` — PID + `flock` ownership gate.
* `Sources/Chronicle/Core/Daemon/DaemonManifest.swift` — epoch, socket, source, sidecar root, and recovery records.
* `Tests/ChronicleTests/Daemon/SourceOwnerTests.swift` — duplicate owner, stale PID, lock release.

### FR-2: Thin RPC client commands

Operator-facing commands are thin RPC clients. They never open mic/sysaudio
hardware. If the daemon is absent, `chronicle start <source>` may spawn it;
other commands return a structured `daemon_unavailable` error with a hint.

**Initial command surface:**

| Command                                                  | Behavior                                                              |                                                  |                                   |
| -------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------ | --------------------------------- |
| `chronicle start full`                                   | Ensure sysaudio + mic daemons are running with default 24/7 sidecars. |                                                  |                                   |
| \`chronicle start sysaudio                               | mic\`                                                                 | Ensure one source daemon is running; idempotent. |                                   |
| \`chronicle stop sysaudio                                | mic                                                                   | full\`                                           | Gracefully stop capture owner(s). |
| `chronicle status --json`                                | Print a complete state snapshot for all known sources.                |                                                  |                                   |
| `chronicle tail --jsonl --source sysaudio --event final` | Subscribe and stream matching events.                                 |                                                  |                                   |
| `chronicle mark "label"`                                 | Append a timestamped control marker to active sessions.               |                                                  |                                   |
| `chronicle clip --last 5m -o out/`                       | Export recent audio + transcript slice from sidecars.                 |                                                  |                                   |
| `chronicle config set --source sysaudio diarize=true`    | Hot-reconfigure supported knobs.                                      |                                                  |                                   |

**Acceptance criteria:**

```gherkin
Given sysaudio is already running
When an agent runs chronicle start sysaudio twice with the same client_req_id
Then both calls return the same daemon id, epoch, socket path, and sidecar root
And only one CoreAudio tap exists
```

```gherkin
Given no daemon is running
When chronicle status --json is executed
Then it returns valid JSON with source states marked "stopped"
And exits 0 because status is idempotent and safe
```

**Files:**

* `Sources/Chronicle/Subcommands/Start.swift`, `Stop.swift`, `Status.swift`, `Tail.swift`, `Mark.swift`, `Clip.swift`, `Config.swift` — thin command veneers.
* `Sources/Chronicle/Core/Daemon/ChronicleRPCClient.swift` — Unix-socket JSON-RPC client.
* `Tests/ChronicleTests/Subcommands/DaemonClientCommandTests.swift` — commands serialize RPCs and handle daemon absence.

### FR-3: Self-describing JSON-RPC API

The daemon exposes JSON-RPC 2.0 over a Unix socket. `meta.schema` is stable and
safe: agents call it first to discover methods, event types, schemas, and
version compatibility.

**Required methods:**

| Method                | Mutates | Purpose                                                     |
| --------------------- | ------- | ----------------------------------------------------------- |
| `meta.schema`         | No      | Return OpenRPC/schema, version, examples, capability flags. |
| `status.get`          | No      | Return complete idempotent state snapshot.                  |
| `capture.ensure`      | Yes     | Ensure source capture is running.                           |
| `capture.stop`        | Yes     | Gracefully stop source capture.                             |
| `capture.reconfigure` | Yes     | Apply supported live config changes.                        |
| `lease.acquire`       | Yes     | Acquire a TTL lease for higher-level operations.            |
| `lease.renew`         | Yes     | Extend a lease.                                             |
| `lease.release`       | Yes     | Release a lease early.                                      |
| `events.subscribe`    | No      | Stream filtered events over the socket.                     |
| `mark.create`         | Yes     | Append a human/agent marker.                                |
| `clip.create`         | Yes     | Export a recent time window.                                |

**Acceptance criteria:**

```gherkin
Given a daemon is running
When an agent calls meta.schema
Then the response includes protocolVersion, daemonVersion, methods, event schemas, error codes, and examples
And every mutating method schema marks client_req_id as required
```

```gherkin
Given an agent sends malformed JSON-RPC
When the daemon rejects the request
Then the error object contains code, retriable, hint, and no Swift stack trace
```

**Files:**

* `Sources/Chronicle/Core/Daemon/RPCProtocol.swift` — JSON-RPC envelopes and typed errors.
* `Sources/Chronicle/Core/Daemon/OpenRPCSchema.swift` — static schema producer.
* `Sources/Chronicle/Core/Daemon/RPCServer.swift` — request router and socket lifecycle.
* `Tests/ChronicleTests/Daemon/RPCProtocolTests.swift` — schema, malformed requests, typed errors.

### FR-4: Versioned append-only event streams

Every daemon-owned JSONL line starts with a common envelope:

```json
{"v":1,"seq":42,"epoch":"2026-05-28T15:01:02Z-a1b2","source":"sysaudio","stream":"trace","t_mono":123.456,"t_wall":"2026-05-28T15:04:05.678-03:00","type":"transcript.final"}
```

`trace.jsonl` remains transcript/source truth; `control.jsonl` carries lifecycle,
RPC mutation, heartbeat, marker, reconfigure, and error events;
`manifest.jsonl` carries daemon epochs, sidecar roots, recovery decisions, and
session metadata.

**Acceptance criteria:**

```gherkin
Given the daemon writes trace/control/manifest JSONL
When jq parses all complete lines
Then every line has v=1, seq, epoch, source, t_mono, t_wall, and type
And seq is strictly increasing per source+stream+epoch
```

```gherkin
Given the daemon is killed with SIGKILL during a write
When it restarts
Then it ignores at most one torn trailing line, appends a recovery event, and continues with a new epoch
```

**Files:**

* `Sources/Chronicle/Core/Daemon/DaemonEvent.swift` — common JSONL envelope.
* `Sources/Chronicle/Core/Daemon/DaemonEventLog.swift` — locked append/read recovery.
* `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift` — adopt/common-map daemon envelope where needed.
* `Tests/ChronicleTests/Daemon/DaemonEventLogTests.swift` — version fields, sequence, torn-line recovery.

### FR-5: Leases and idempotency

Clients use leases for multi-step operations that should not be stolen mid-flight
(`clip.create`, future export passes). Leases are advisory and TTL-bound; they are
not the physical-source lock. Mutating requests require `client_req_id` so agents
can retry safely after timeouts.

**Acceptance criteria:**

```gherkin
Given a client acquires a lease with ttl=30s
When the client disappears
Then the lease expires automatically and a control event records the expiry
```

```gherkin
Given capture.reconfigure succeeds for client_req_id "abc"
When the same request is retried with client_req_id "abc"
Then the daemon returns the stored success response without applying the change twice
```

**Files:**

* `Sources/Chronicle/Core/Daemon/LeaseStore.swift` — TTL leases and expiry events.
* `Sources/Chronicle/Core/Daemon/IdempotencyStore.swift` — recent request result cache.
* `Tests/ChronicleTests/Daemon/LeaseStoreTests.swift` — expiry, renew, release, conflict.
* `Tests/ChronicleTests/Daemon/IdempotencyStoreTests.swift` — retry success/error replay.

### FR-6: Subscribe without polling

`events.subscribe` streams filtered events over the socket. Filters include
source, stream, type prefix, finals-only, speaker-known, since sequence, and
heartbeat inclusion. The daemon applies filters server-side to avoid every agent
tailing every sidecar file.

**Acceptance criteria:**

```gherkin
Given sysaudio is producing finals
When an agent subscribes with {"source":"sysaudio","type":"transcript.final"}
Then only final transcript events stream to that socket
And the client receives heartbeats or an EOF within the configured liveness window
```

```gherkin
Given a slow subscriber cannot keep up
When its queue exceeds the configured bound
Then the daemon applies the documented drop policy, emits subscriber_lagged, and preserves capture throughput
```

**Files:**

* `Sources/Chronicle/Core/Daemon/EventHub.swift` — in-process pub/sub with bounded queues.
* `Sources/Chronicle/Core/Daemon/EventFilter.swift` — filter grammar.
* `Tests/ChronicleTests/Daemon/EventHubTests.swift` — filtering, backpressure, heartbeat, since-seq replay.

### FR-7: Hot reconfiguration with safety gates

Supported live changes apply without capture restart when safe:

| Setting                        | Hot?                    | Behavior                                                                               |
| ------------------------------ | ----------------------- | -------------------------------------------------------------------------------------- |
| `quiet`, `verbose`, `debugTap` | Yes                     | Change diagnostic output policy.                                                       |
| `diarize`                      | Yes                     | Start/stop progressive diarizer layer; rough transcript continues.                     |
| `tagEvery`                     | Yes                     | Start/stop or change tag cadence.                                                      |
| `locale`                       | Conditional             | Pin/hot-swap via existing transcriber swap path when safe; otherwise structured error. |
| `rotateAudio`, `scratchTtl`    | Yes for future segments | Active segment is not rewritten.                                                       |
| `source`                       | No                      | Requires a different source daemon.                                                    |
| `audioFormat`                  | No by default           | Requires restart unless implementation proves safe segment boundary switch.            |

**Acceptance criteria:**

```gherkin
Given sysaudio capture is running without diarize
When capture.reconfigure sets diarize=true
Then transcript events continue during Sortformer prewarm
And later events may include speakerId
And control.jsonl records the reconfigure start and completion
```

```gherkin
Given capture.reconfigure requests source="mic" on a sysaudio daemon
When the daemon rejects the request
Then it returns code="unsupported_reconfigure", retriable=false, and hint="start the mic daemon instead"
```

**Files:**

* `Sources/Chronicle/Core/Daemon/CaptureConfiguration.swift` — typed config and hot-swap policy.
* `Sources/Chronicle/Core/Daemon/DaemonCaptureSession.swift` — owns current pipeline and reconfiguration.
* `Sources/Chronicle/Subcommands/Mic.swift` / `SysAudio.swift` — extract reusable pipeline construction for daemon use.
* `Tests/ChronicleTests/Daemon/CaptureConfigurationTests.swift` — hot/restart/reject policy.

### FR-8: Heartbeats, status, and recovery

The daemon emits heartbeat events and serves a complete status snapshot. Status
is safe, idempotent, and machine-readable; agents should never parse stderr to
know if capture works.

**Status snapshot includes:**

* source state: `stopped`, `starting`, `capturing`, `degraded`, `stopping`, `failed`
* PID, epoch, socket path, sidecar root
* current session paths: audio segments, scratch dir, live/finals/trace/control
* last heartbeat, last audio peak, `sessionPeak`, buffer counts
* transcript counters: volatile/final counts, latency avg/p95/max
* diarizer counters: prewarm state, speaker count, known/unknown labels
* disk/backpressure state and last structured error

**Acceptance criteria:**

```gherkin
Given sysaudio is running but no app is producing audio
When status.get is called
Then state is "capturing" with lastPeak=0 and a hint that output may be idle
And it is not reported as a permission failure unless runtime evidence supports that
```

```gherkin
Given the daemon process dies without graceful shutdown
When an agent subscribes or polls status
Then it observes heartbeat expiry and a structured daemon_unavailable state, not a stale success
```

**Files:**

* `Sources/Chronicle/Core/Daemon/DaemonStatus.swift` — status model.
* `Sources/Chronicle/Core/Daemon/Heartbeat.swift` — heartbeat writer and expiry calculation.
* `Tests/ChronicleTests/Daemon/DaemonStatusTests.swift` — idle output, stale heartbeat, degraded state.

---

## 6. Non-Functional Requirements

| Category          | Requirement                                                                                                                                        |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Latency**       | RPC status replies under 100 ms locally; subscribe delivery under 250 ms under normal load; rough transcript path unchanged from current baseline. |
| **Resilience**    | No mutating operation may corrupt existing sidecars on retry, timeout, SIGTERM, or SIGKILL.                                                        |
| **Backpressure**  | Slow subscribers and full disks degrade explicitly; capture never blocks forever on an agent client.                                               |
| **Privacy**       | Unix socket is local-only; no network listeners; no cloud calls in production capture.                                                             |
| **Observability** | Agents use `status.get`, `events.subscribe`, and JSONL sidecars instead of stderr scraping.                                                        |
| **Compatibility** | Current `mic` and `sysaudio` CLI behavior stays usable as rollback/direct mode until daemon proves stable.                                         |

---

## 7. Risks & Mitigations

| Risk                                                         | Severity | Mitigation                                                                                                                            |
| ------------------------------------------------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Daemon abstraction regresses current proven sysaudio capture | High     | Preserve direct CLI path; keep rollback tag; first implementation wraps existing pipeline without changing CoreAudio tap internals.   |
| SIGTERM still hangs in analyzer finalization                 | High     | Add bounded stop state machine and tests; daemon stop escalates INT → TERM → KILL while preserving JSONL/scratch recovery evidence.   |
| Agents accidentally fork duplicate capture owners            | High     | SourceOwner PID + flock gate before opening audio resources; `start` becomes idempotent ensure.                                       |
| Slow subscribers block capture                               | Medium   | Bounded EventHub queues with explicit drop policy and `subscriber_lagged` events.                                                     |
| JSON-RPC schema drifts from implementation                   | Medium   | `meta.schema` generated from typed method table; test asserts every registered method appears.                                        |
| Disk fills during 24/7 recording                             | High     | Status reports disk pressure; backpressure policy returns structured errors and emits events; retention/pruning remains separate PRD. |

---

## 8. Design Decisions

### D1: One daemon per source, not many capture processes

**Decision:** one `mic` daemon and one `sysaudio` daemon own physical sources.
Clients consume/control via RPC.

**Rationale:** physical capture sources have side effects: TCC prompts, CoreAudio
taps, aggregate devices, output-device rebuilds, scratch writers. Duplicating
those for each agent creates conflicts and data ambiguity. A source owner keeps
capture stable and makes every client operation auditable.

### D2: JSON-RPC over Unix socket, not gRPC or HTTP

**Decision:** JSON-RPC 2.0 on a Unix-domain socket.

**Rationale:** JSON-RPC is easy for Swift, shell, jq, and LLM agents. Unix socket
permissions avoid exposing a network API. HTTP/gRPC would add framework weight
without solving a current problem.

### D3: Leases, not locks, for client operations

**Decision:** physical ownership uses PID + `flock`; client coordination uses
TTL leases.

**Rationale:** a crashed agent must not wedge Chronicle. Leases auto-expire and
emit control events. They express intent without owning the physical source.

### D4: Append-only logs as source of truth

**Decision:** daemon state changes are written to JSONL before they are exposed
as success to clients where practical.

**Rationale:** append-only logs are crash-friendly, diffable, and recoverable.
They match the existing `trace.jsonl` direction and let agents reconstruct what
happened without trusting a running daemon.

### D5: Progressive quality layers stay non-blocking

**Decision:** rough transcript capture starts first; diarization, tagging, and
future identity/summarization layers attach after they are ready.

**Rationale:** the user-visible invariant is near-real-time rough transcript.
Quality layers improve the record but must never delay the first transcript path.

---

## 9. File Breakdown

| File                                                | Change type | Description                                                                                                           |
| --------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------- |
| `Sources/Chronicle/Chronicle.swift`                 | Modify      | Register daemon/client subcommands.                                                                                   |
| `Sources/Chronicle/Subcommands/Daemon.swift`        | New         | `chronicle daemon run` source-owner entry point.                                                                      |
| `Sources/Chronicle/Subcommands/Start.swift`         | New         | Thin ensure/start RPC client.                                                                                         |
| `Sources/Chronicle/Subcommands/Stop.swift`          | New         | Thin stop RPC client.                                                                                                 |
| `Sources/Chronicle/Subcommands/Status.swift`        | New         | Thin status RPC client with `--json`.                                                                                 |
| `Sources/Chronicle/Subcommands/Tail.swift`          | New         | Thin subscribe client for JSONL/event streaming.                                                                      |
| `Sources/Chronicle/Subcommands/Mark.swift`          | New         | Marker creation client.                                                                                               |
| `Sources/Chronicle/Subcommands/Clip.swift`          | New         | Recent clip/export client.                                                                                            |
| `Sources/Chronicle/Subcommands/Config.swift`        | New         | Hot reconfiguration client.                                                                                           |
| `Sources/Chronicle/Core/Daemon/`                    | New         | Source owner, RPC protocol/server/client, schema, leases, idempotency, event hub, status, heartbeat, capture session. |
| `Sources/Chronicle/Subcommands/Mic.swift`           | Refactor    | Extract reusable capture pipeline construction for daemon mode; preserve direct CLI behavior.                         |
| `Sources/Chronicle/Subcommands/SysAudio.swift`      | Refactor    | Same extraction for CoreAudio tap source; preserve direct CLI behavior.                                               |
| `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift` | Modify      | Align event envelope where daemon owns sequence/epoch; preserve existing reader compatibility.                        |
| `Tests/ChronicleTests/Daemon/`                      | New         | Unit tests for ownership, RPC, schema, leases, idempotency, event hub, status, recovery.                              |
| `scripts/smoke-sysaudio-diarize.sh`                 | Reuse       | Baseline direct-mode smoke remains rollback verification.                                                             |
| `scripts/smoke-daemon-kill9.sh`                     | New         | End-to-end daemon crash recovery smoke.                                                                               |
| `README.md`                                         | Modify      | Document operator/agent command surface and rollback/direct-mode escape hatch.                                        |
| `docs/STATUS.md`                                    | Modify      | Add daemon control-plane phase and verification receipts.                                                             |

---

## 10. Dependencies & Constraints

* macOS 26+, Apple Silicon, Chronicle `.app` bundle, and existing TCC grants remain required for live capture.
* Daemon must run through the installed signed app path for live source access.
* Swift 6.2 package remains dependency-light; do not add a server framework unless JSON-RPC over `Network`/Foundation proves insufficient.
* `$XDG_RUNTIME_DIR` may be absent on macOS; fallback runtime dir must be per-user and mode `0700`.
* Existing direct CLI subcommands remain supported until daemon smoke gates pass.

---

## 11. Rollout Plan

1. **P12a — Crash and ownership test harness.** Add daemon test scaffolding, `SourceOwner`, event envelope, and `scripts/smoke-daemon-kill9.sh` before the full RPC surface.
2. **P12b — JSONL v1 + manifest/control logs.** Land common event envelope, daemon epochs, heartbeats, and recovery events.
3. **P12c — RPC meta/status.** Implement socket server, `meta.schema`, `status.get`, and `chronicle status --json`.
4. **P12d — Capture ensure/stop.** Wrap existing sysaudio pipeline in `daemon run`; add `start`/`stop`; prove no duplicate CoreAudio taps.
5. **P12e — Leases + idempotency.** Add `client_req_id` enforcement for mutations and TTL lease store.
6. **P12f — Subscribe + tail.** Add EventHub, filters, slow-subscriber policy, and `chronicle tail --jsonl`.
7. **P12g — Hot reconfigure.** Add supported config changes, especially enabling/disabling diarize without blocking rough transcript.
8. **P12h — Full operator UX.** Add `chronicle start full`, `mark`, `clip --last`, README docs, and status dashboard receipts.

Each phase must pass `swift test`. Phases touching live capture must also pass
the current direct smoke and at least one daemon smoke using generated
ElevenLabs fixtures or deterministic file-driven input.

---

## 12. Open Questions

| #  | Question                                                                                 | Default for implementation                                                            |
| -- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Q1 | Should `chronicle start full` automatically start both mic and sysaudio on this machine? | Yes, but allow `--no-mic` / `--no-sysaudio` and keep per-source start commands.       |
| Q2 | Where should default 24/7 sidecars live?                                                 | `~/Documents/chronicle/live/<date>-<source>/` initially, matching current runs.       |
| Q3 | How long should idempotency records be retained?                                         | 24 hours or daemon epoch lifetime, whichever is shorter.                              |
| Q4 | Should `clip --last` hold a lease?                                                       | Yes; lease prevents competing exports from pruning or rewriting the same temp output. |
| Q5 | Should daemon mode replace direct `mic` / `sysaudio` eventually?                         | Not until P12 smoke gates pass repeatedly; direct mode remains rollback escape hatch. |

---

## 13. Related

| Artifact                                                                                   | Relationship                                                         |
| ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| [PRD-001 resilient multi-source daemon](PRD-001-resilient-multi-source-daemon.md)          | Current capture/sidecar/transcript foundation.                       |
| [PRD-002 speaker identity memory](PRD-002-speaker-identity-memory.md)                      | Future refinement layer consuming stable speaker-labeled streams.    |
| [ADR-0001 modular pipeline architecture](../adr/ADR-0001-modular-pipeline-architecture.md) | Constrains extraction of reusable capture pipeline components.       |
| [ADR-0004 Tahoe system audio capture](../adr/ADR-0004-tahoe-system-audio-capture.md)       | Current CoreAudio tap source decision.                               |
| [ADR-0005 audio sidecar reuse boundary](../adr/ADR-0005-audio-sidecar-reuse-boundary.md)   | Sidecar reuse constraints for daemon-owned capture.                  |
| `scripts/smoke-sysaudio-diarize.sh`                                                        | Direct-mode rollback smoke and generated-voice diarization baseline. |

---

## 14. Changelog

| Date       | Change                                                                              | Author |
| ---------- | ----------------------------------------------------------------------------------- | ------ |
| 2026-05-28 | Initial daemon control-plane draft after rollback baseline and Opus subagent review | Victor |

---

## 15. Verification Appendix

Before accepting the first daemon implementation:

1. Run `swift test`.
2. Run `scripts/smoke-sysaudio-diarize.sh` to prove direct-mode rollback still works.
3. Start `chronicle daemon run --source sysaudio` through `/Applications/chronicle.app` and verify `status.get` reports `capturing` with nonzero or idle-explained peak state.
4. Run `chronicle start sysaudio` twice and verify one owner, one socket, one sidecar root.
5. Subscribe via `chronicle tail --jsonl --source sysaudio --event transcript.final`; play generated ElevenLabs fixture audio; verify final events arrive without polling.
6. Run `capture.reconfigure diarize=true` while capture is active; verify transcript events continue before Sortformer prewarm completes and later events gain `speakerId`.
7. Send `kill -9` to the daemon during audio playback; verify JSONL complete lines parse, at most one torn line is ignored, scratch PCM is recoverable, and restart appends a recovery event with a new epoch.
8. Fill or simulate disk pressure; verify status reports backpressure and clients receive structured retriable/non-retriable errors with hints.
