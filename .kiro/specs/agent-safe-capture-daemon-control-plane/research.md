# Research & Design Decisions

## Summary

- **Feature**: `agent-safe-capture-daemon-control-plane`
- **Discovery Scope**: Complex Integration / Extension
- **Key Findings**:
  - Chronicle already has the core capture and sidecar primitives needed for daemon mode: `Mic.swift`, `SysAudio.swift`, `JSONLTraceSink`, `AtomicFile`, `SessionOutputPaths`, `SignalHandler`, and `MonotonicClock`.
  - The design should build a local control plane around the existing direct capture paths instead of replacing CoreAudio taps, SpeechAnalyzer, sidecar sinks, or diarization internals.
  - The main new boundary is coordination: source ownership, JSON-RPC contracts, idempotent mutations, subscription delivery, health state, and crash recovery.

## Research Log

### Existing Capture Pipeline

- **Context**: Requirements require daemon mode without regressing the proven direct sysaudio/mic path.
- **Sources Consulted**:
  - `Sources/Chronicle/Subcommands/SysAudio.swift`
  - `Sources/Chronicle/Subcommands/Mic.swift`
  - `Sources/Chronicle/Core/Diarize/StreamingDiarizer.swift`
  - `Sources/Chronicle/Core/Sinks/TranscriptionSink.swift`
- **Findings**:
  - Existing subcommands currently combine CLI parsing, source setup, sidecar setup, locale/diarizer wiring, result handling, and shutdown behavior in one file.
  - The daemon needs reusable pipeline construction without changing the hot CoreAudio tap and SpeechAnalyzer contracts first.
  - Direct subcommands remain useful rollback paths and smoke-test targets.
- **Implications**:
  - Design introduces `Core/Capture/LiveCaptureSession` and `LiveCaptureConfiguration` as the seam for both direct commands and daemon sessions.
  - First daemon implementation should extract existing behavior rather than rewrite capture internals.

### Durable Event and File Primitives

- **Context**: Requirements need JSONL v1, kill -9 recovery, sequences, epochs, and heartbeats.
- **Sources Consulted**:
  - `Sources/Chronicle/Core/Runtime/AtomicFile.swift`
  - `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift`
  - `Sources/Chronicle/Core/Runtime/MonotonicClock.swift`
  - `Sources/Chronicle/Core/Runtime/SessionOutputPaths.swift`
- **Findings**:
  - `AtomicFile.appendLine` already uses Darwin `O_APPEND` plus `flock(LOCK_EX)` and documents at-most-one torn final line.
  - `JSONLTraceSink` already writes source-aware schema-versioned trace events with monotonic offset and wallclock.
  - Existing event naming is trace-specific (`schemaVersion`, `eventId`, `wallclock`, `monotonicOffsetMs`) while the daemon PRD asks for a compact common envelope (`v`, `seq`, `epoch`, `t_mono`, `t_wall`, `type`).
- **Implications**:
  - Design keeps existing trace compatibility and adds daemon-owned event records for manifest/control/heartbeat streams.
  - Trace migration should be additive: daemon can wrap or map trace events without breaking existing `merge` readers.

### Runtime Control and Shutdown

- **Context**: Existing live process termination was unreliable enough to require INT → TERM → KILL fallback in smoke scripts.
- **Sources Consulted**:
  - `Sources/Chronicle/Core/Runtime/SignalHandler.swift`
  - `scripts/smoke-sysaudio-diarize.sh`
  - `docs/STATUS.md`
- **Findings**:
  - `SignalHandler` provides one-shot signal waiting, but the current direct mode does not expose machine-readable stop progress or escalation state.
  - Smoke scripts already encode the practical shutdown ladder.
- **Implications**:
  - Daemon stop state is explicit: stopping, finalizing, escalating, stopped, failed.
  - Tests must verify bounded graceful stop and hard-kill recovery separately.

### Build vs Adopt

- **Context**: Need local control protocol with self-described contracts and streaming events.
- **Options Reviewed**:
  - HTTP server framework: more dependencies and an unnecessary network surface.
  - gRPC: strong contracts but heavier Swift/runtime cost and worse shell/agent ergonomics.
  - JSON-RPC 2.0 over Unix socket: small, local, easy for Swift and agents.
- **Implications**:
  - Build the minimal JSON-RPC transport in tree using Swift Foundation/Darwin primitives.
  - Adopt JSON-RPC 2.0 envelope conventions and OpenRPC-style schema shape, but do not add a schema registry or network framework.

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
| --- | --- | --- | --- | --- |
| Direct process per client | Every agent starts `mic` or `sysaudio` as needed | Already works, no daemon code | Duplicate physical capture, no shared status, unsafe retries | Rejected for 24/7 control |
| Supervisor-only wrapper | Shell/process supervisor owns capture and agents tail files | Minimal code | Still lacks idempotent control, schema, subscribe, leases | Useful as transitional operator tooling only |
| Source-owner daemon with thin RPC clients | One owner per source, many local clients | Matches requirements, safe for agents, preserves direct mode | Requires new coordination layer | Selected |
| Remote service | Daemon exposes HTTP/gRPC over TCP | Flexible clients | Network exposure, auth scope, unnecessary complexity | Out of scope |

## Design Decisions

### Decision: Source owner before RPC richness

- **Context**: Duplicate source capture is the highest-risk agent failure mode.
- **Alternatives Considered**:
  1. Implement full RPC first, then guard duplicate starts.
  2. Implement PID/flock ownership and daemon epoch before mutating controls.
- **Selected Approach**: Build `SourceOwner` and `DaemonManifest` first.
- **Rationale**: The first implementation slice can prove no double CoreAudio tap before adding higher-level methods.
- **Trade-offs**: Early daemon is not very useful until RPC lands, but it protects the physical resource invariant.
- **Follow-up**: Add duplicate-owner unit tests and a live smoke that verifies second daemon fails before opening capture.

### Decision: Separate control events from transcript trace compatibility

- **Context**: Existing trace events are already consumed by merge and smoke tooling.
- **Alternatives Considered**:
  1. Rename all trace fields to the daemon envelope immediately.
  2. Keep trace schema as-is and add daemon event logs with the common envelope.
  3. Write only one unified event log.
- **Selected Approach**: Add `DaemonEvent`/`DaemonEventLog` for manifest/control/heartbeat and provide additive trace mapping for daemon-owned trace events.
- **Rationale**: Existing tools keep working while daemon-specific events get epoch/sequence/lifecycle semantics.
- **Trade-offs**: There are two related event shapes initially; design must document the mapping.
- **Follow-up**: Consider trace envelope unification only after daemon readers replace current direct readers.

### Decision: Thin CLI clients only

- **Context**: Agents and humans need command-line UX, but business logic must not fork across commands.
- **Alternatives Considered**:
  1. Put start/stop/status logic in each command.
  2. Keep commands as serialization/rendering wrappers over `ChronicleRPCClient`.
- **Selected Approach**: CLI commands are thin RPC clients.
- **Rationale**: Retry semantics, idempotency, and source state stay daemon-owned and testable once.
- **Trade-offs**: Commands depend on daemon availability except for `start` bootstrap behavior.
- **Follow-up**: Command tests assert no client command opens audio resources.

### Decision: TTL leases for client coordination

- **Context**: Agents can disappear mid-operation.
- **Alternatives Considered**:
  1. Persistent locks released only by clients.
  2. No client coordination.
  3. TTL leases with renew/release.
- **Selected Approach**: Use TTL leases for multi-step client operations, separate from physical source ownership.
- **Rationale**: Leases prevent orphaned coordination from wedging 24/7 capture.
- **Trade-offs**: Clients must renew for long operations.
- **Follow-up**: Lease expiry emits control events and appears in status.

## Risks & Mitigations

- Refactoring direct `Mic`/`SysAudio` could regress live capture — extract a shared capture session behind existing direct command behavior and keep direct smoke in the verification gate.
- JSONL envelope drift could break readers — keep existing trace schema additive and test both direct and daemon reads.
- Socket server complexity could stall progress — land `meta.schema`/`status.get` before streaming/mutating methods.
- Slow subscribers could block capture — use bounded subscriber queues and explicit lag events.
- Shutdown can still hang in Apple analyzer finalization — daemon stop state uses bounded finalization and escalation, with committed sidecars as recovery authority.

## References

- `.kiro/specs/agent-safe-capture-daemon-control-plane/requirements.md` — approved requirements.
- `.kiro/steering/product.md` — local-first capture and runtime-evidence invariant.
- `.kiro/steering/tech.md` — macOS 26, Swift 6.2, signed app/TCC, CoreAudio tap constraints.
- `.kiro/steering/structure.md` — `Subcommands/` veneers and `Core/` domain boundaries.
- `docs/prd/PRD-003-agent-safe-capture-daemon-control-plane.md` — PRD source material.
- `docs/prd/PRD-001-resilient-multi-source-daemon.md` — existing sidecar and daemon foundation.

---

# Post-Implementation Gap Validation (2026-05-28)

## Trigger

After tasks 1.1–7.2 were marked complete and pushed (10 commits, 195 swift tests
passing, 2 daemon smokes green), an `architect-reviewer` pass via
`claude-opus-4-7` reported **BLOCK · scaffolding not functional** with
5 CRITICAL, 6 HIGH, 4 MEDIUM, 2 LOW findings. This appendix re-runs gap analysis
against the spec using the implemented codebase as the baseline, treating the
review evidence as ground truth.

## Analysis Summary

- The actor/state graph (`Daemon`, `DaemonCoordinator`, `LiveCaptureSession`,
  `EventHub`, `LeaseStore`, `IdempotencyStore`, `SourceOwner`, `DaemonEventLog`,
  `RuntimePaths`, `ClipCoordinator`, `ControlClients`, `EventClients`) is
  named correctly and tested in isolation.
- The client-facing RPC surface (`Sources/Chronicle/Core/Daemon/RPCTransport.swift`)
  is not wired to that graph; `route` only honors `status.get`, and even that
  returns a hardcoded `lifecycle=stopped`. Every other registered method falls
  into the `RPCProtocol.dispatch` placeholder that returns `{"accepted": true}`.
- `LiveCaptureSession` never opens audio devices. Direct `mic` / `sysaudio`
  subcommands still own the real capture pipeline and do not delegate.
- `EventHub` is constructed but never `publish()`-ed to; coordinator events
  accumulate in a private array.
- Honest pieces: `SourceOwner` (cross-process flock + PID liveness),
  `DaemonEventLog` (append-only JSONL with torn-trailer tolerance, epoch
  increment, recovery event).
- Net: only Requirements 1.1, 1.3, 1.4, 4.1–4.3, 9.3, 9.4 are met end-to-end.
  Requirements 2, 3, 5, 6, 7, 8 are met inside the coordinator actor but
  invisible across the only client-facing surface.

## Requirement-to-Asset Map

Tags: `Met` (functional end-to-end), `Met-in-actor` (coordinator works, RPC
stub), `Missing` (no implementation), `Constraint` (existing decision blocks),
`Research Needed` (uncertain).

| Req | Acceptance bullet | Asset(s) | Status | Evidence / Note |
| --- | --- | --- | --- | --- |
| 1.1 | reject second owner before live capture | `Sources/Chronicle/Core/Daemon/SourceOwner.swift:113-130`, `Daemon.swift:42-46` | Met | `DaemonRunTests.duplicateStartRejectsWithAlreadyOwnedWithoutRecreatingSocket`; smoke `scripts/smoke-daemon-integration.sh` covers cross-process path |
| 1.2 | report existing owner + remediation | `SourceOwner.swift:157-200` (`SourceOwnerSnapshot.remediation`) | Met-in-actor | RPC layer never surfaces snapshot; client receives plain stderr |
| 1.3 | distinguish stale state from active | `SourceOwner.inspect()`; `kill(pid, 0)` liveness | Met | Validated by smoke kill-9 path; `DaemonRecoveryTests.simulateHardKill` does **not** validate this — it deletes the pidURL, see HIGH-3 |
| 1.4 | independent ownership for sysaudio + mic | `RuntimePaths(source:)` per-source `sourceDirectory` | Met | Tested |
| 2.1 | duplicate start returns existing running state | `DaemonCoordinator.ensure` `lifecycle == .capturing` branch | Met-in-actor | RPC `capture.ensure` returns `{"accepted":true}` |
| 2.2 | repeated request returns same outcome | `DaemonCoordinator` per-method replay dicts | Met-in-actor (in-memory only) | Replay state lost on daemon restart — see CRITICAL-5 |
| 2.3 | status without owner returns stopped | `DaemonStatus.stopped(source:paths:)` | Met-in-actor | RPC `status.get` hardcodes stopped — accidentally satisfies this bullet only |
| 2.4 | stop without owner is idempotent | `DaemonCoordinator.stop` `lifecycle == .stopped` branch | Met-in-actor | RPC not routed |
| 2.5 | status fields (peak, counters, label state, error) | `DaemonStatus`, `Heartbeat`, `LiveCaptureStatus` | Missing over RPC | `RPCTransport.swift:122-127` only emits source+lifecycle+socket |
| 3.1 | self-describing schema | `OpenRPCSchema.current()` via `meta.schema` | Met for surface, Constraint for accuracy | Schema advertises 11 methods + `no_active_session` / `range_unavailable`; server honors 1. Schema is currently a contract lie. |
| 3.2 | compatibility version on incompatible change | `OpenRPCSchema.protocolVersion` | Met (static) | No bump path tested |
| 3.3 | structured error for malformed / unsupported | `RPCError`, `RPCProtocol.dispatch` | Met | Verified by `RPCProtocolTests` |
| 3.4 | no stack traces in client errors | `RPCError.hint` shape | Met by construction | Reviewed in `RPCProtocol.swift` |
| 4.1 | event envelope (v, seq, epoch, t_mono, t_wall, type, source) | `DaemonEvent` + `DaemonEventLog.append` | Met | Validated by `DaemonEventLogTests` |
| 4.2 | restart records new epoch + recovery event | `Daemon.start` recovery branch | Met | `DaemonRecoveryTests`; live smoke validates cross-process |
| 4.3 | torn trailing record ignored, complete records preserved | `DaemonEventLog.read` | Met | Tested |
| 4.4 | preserve existing transcript/audio durability | n/a — daemon doesn't open audio yet | Missing | `LiveCaptureSession` never writes sidecars; direct path still owns this — see CRITICAL-4 |
| 5.1 | subscribe streams final events | `EventHub.subscribe` exists but unused at RPC; coordinator events not published | Missing over RPC | CRITICAL-3 |
| 5.2 | filters restrict delivery | `EventFilter.matches` | Met-in-actor | Cannot exercise over RPC |
| 5.3 | heartbeat / EOF liveness | `Heartbeat` modeled; no emitter | Missing | No code constructs and publishes heartbeats on a timer |
| 5.4 | bounded slow-subscriber + lag event | `EventSubscriber.enqueue` overflow | Met-in-actor | Tested |
| 6.1 | progressive layer change keeps rough transcript active | `LiveCaptureSession.reconfigure` mutates status struct | Met-in-actor; Missing end-to-end | No real transcript is running to keep "active"; CRITICAL-4 |
| 6.2 | unsafe active changes rejected w/ alternative | `LiveCaptureConfiguration.policy` + `DaemonCoordinator.reconfigure` | Met-in-actor | RPC `capture.reconfigure` returns placeholder |
| 6.3 | start/complete control events | `DaemonCoordinator.appendControlEvent` for reconfigure | Met-in-actor | Events sink to private array; durable JSONL never sees them |
| 6.4 | layer failure separated from source health | Coordinator returns `ReconfigureResult.error` w/ `invalid_config` | Met-in-actor | Not surfaced over RPC |
| 7.1 | active marker → timestamped event | `DaemonCoordinator.createMarker` | Met-in-actor | Marker events do **not** reach `DaemonEventLog` durable JSONL |
| 7.2 | no-active-session marker rejected | `DaemonCoordinator.createMarker` no-active branch | Met-in-actor | Tested |
| 7.3 | available clip exports | `ClipCoordinator.export` via `ScratchExporter` | Met-in-actor | No scratch is being written by daemon; needs CRITICAL-4 |
| 7.4 | unavailable clip → range error w/ available range | `ClipCoordinator.export` `rangeUnavailable` branch | Met-in-actor | Tested |
| 7.5 | multi-step coord state must not orphan | `LeaseStore` re-instantiated per `createClip` call | Met-by-amnesia | HIGH-2: requirement passes only because lease store is rebuilt; cannot honor `lease.*` RPC |
| 8.1 | periodic heartbeats while running | No emitter loop | Missing | No timer; `Heartbeat` constructed lazily in `status()` |
| 8.2 | idle output separate from failure | `Heartbeat.idleOutput` field | Met-in-actor | Field exists, no emitter, no RPC path |
| 8.3 | heartbeat expiry → stale/unavailable | `DaemonStatus.project` freshness logic | Met-in-actor | No emitter to expire |
| 8.4 | runtime evidence is health authority | n/a — no runtime evidence produced | Missing | CRITICAL-4 |
| 9.1 | normal stop attempts graceful finalization | `DaemonCoordinator.stop` + `LiveCaptureSession.stop` | Met-in-actor | No real finalization to attempt yet |
| 9.2 | bounded stop escalates, preserves evidence | `StopOutcome` enum present, escalation path unused | Missing | No bounded timer; smoke uses SIGTERM only |
| 9.3 | kill -9 leaves complete records, recent audio recoverable | `DaemonEventLog` torn-trailer + `RollingPCMScratchSink` (existing direct path) | Met for events, Missing for audio under daemon | Daemon doesn't write scratch |
| 9.4 | restart reports previous termination | `Daemon.start` recovery event | Met | Smoke validates |
| 10.1 | local-only control | Unix domain socket only | Met | No TCP listener |
| 10.2 | no cloud required for production | All daemon paths local | Met | Verified by inspection |
| 10.3 | generated voices test-only | `scripts/smoke-sysaudio-diarize.sh` is the only consumer of ElevenLabs | Met | Inspected |
| 10.4 | preserve direct rollback path | `Mic.swift` / `SysAudio.swift` untouched in behavior | Met | Live capture (PIDs from `pgrep`) continued through implementation; CLI namespace collision risk is HIGH-5 |

## Gap Categorization

### CRITICAL — daemon does not perform its job

- **C1. RPC server unwired to coordinator.** `RPCTransport.swift:112-130`. Fix:
  inject `DaemonCoordinator` + `EventHub` into `RPCServer`; replace
  `RPCProtocol.dispatch` placeholder with per-method async handlers serialized
  back into JSON-RPC.
- **C2. `status.get` hardcoded stopped.** `RPCTransport.swift:122-127`. Fix:
  delegate to `coordinator.status()` and encode full `DaemonStatus` JSON
  envelope.
- **C3. `EventHub` never published to.** `Daemon.swift:35`, no `.publish()`
  call site. Fix: inject hub into coordinator; every `events.append(event)`
  must also `eventHub.publish(event)` and persist to `DaemonEventLog`.
- **C4. `LiveCaptureSession` never opens audio.**
  `Sources/Chronicle/Core/Capture/LiveCaptureSession.swift:62-72`. Fix: extract
  engine/source/analyzer/sinks construction from `Mic.swift:80-585` and
  `SysAudio.swift:107-525` into the session type; direct subcommands then
  delegate; daemon's `coordinator.ensure` becomes a real capture start.
- **C5. Idempotency replay non-durable.** `DaemonCoordinator.swift:37-42`.
  Either delete `IdempotencyStore` and accept in-memory replay (and amend
  Req 2.2 + 9.3 interaction in this doc), or replace per-method dicts with one
  `IdempotencyStore` persisted under `paths.sourceDirectory`.

### HIGH — contract integrity

- **H1. Schema vs server divergence.** `OpenRPCSchema.swift:9-22` registers
  methods + codes the server cannot honor. Fix: trim schema to implemented
  intersection until C1 lands, or block merge until parity.
- **H2. `LeaseStore` rebuilt per call.** `DaemonCoordinator.swift:181-184`.
  Fix: lease store is coordinator-lifetime; expire via TTL sweep; wire
  `lease.acquire/renew/release` RPC methods.
- **H3. `simulateHardKill` doesn't simulate.** `Daemon.swift:78-86` deletes
  pidURL. Fix: close fd directly without invoking lease `release()` (which
  removes the pid file). Add a test that calls `inspect()` after the simulated
  kill and asserts `lifecycle == .stale, isActive == false`.
- **H4. Tests assert the placeholder.**
  `ControlClientCommandsTests.swift:42,54` encode `accepted == .bool(true)` as
  pass. `DaemonCommandRegistrationTests` is pure self-reference. Fix: add an
  RPC round-trip test that calls `StartClient.send` against a running `Daemon`
  and expects `lifecycle == capturing` and structured `existingOwner` envelope.
- **H5. CLI namespace flat-mount.** `Chronicle.swift:9-32` registers `start`,
  `stop`, `status`, `tail`, `mark`, `clip`, `config`, `daemon-run` next to
  `mic`, `sysaudio`, `live`. Fix: nest under `chronicle daemon { run, start,
  stop, status, tail, mark, clip, config }`. Update tasks.md task 6.4.
- **H6. Cross-process flock not covered by Swift tests.** Smoke alone covers
  this. Acceptable if documented; otherwise add a `Process`-spawned holder
  test.

### MEDIUM — duplication / inconsistency

- **M1. Two status projections.** Ad-hoc in `RPCServer.route` + `coordinator.status()`.
- **M2. Events live in two places.** Coordinator local array vs `DaemonEventLog`
  durable JSONL.
- **M3. `ConfigClient` sends `change` as JSON string.** Schema declares object.
  `EventClients.swift` `ConfigClient.send`.
- **M4. `audioFormat` accepted as arbitrary string at init.** Validate at
  construction.

### LOW — docs / examples

- **L1. README / `docs/STATUS.md` do not flag RPC as stub-only.**
- **L2. `OpenRPCSchema.exampleDefinitions` covers 3 of 11 methods.**

## Implementation Approach Options

### Option A: Wire RPC to existing coordinator, defer real audio

- Fix C1, C2, C3, C5, H1, H2, H3, H4, H5, H6, M1–M4.
- Leave `LiveCaptureSession` as a pure state model. Document Req 1, 4.4, 6.1,
  8.4, 9.1 as "control plane meets criteria; runtime evidence still produced by
  direct `Mic`/`SysAudio` rollback path."
- Direct subcommands remain authoritative for real capture; daemon is a control
  + status + recovery surface that points at direct sidecar paths.
- **Trade-offs**: ✅ small, well-bounded; ✅ unblocks agents that only need
  status/subscribe/marker/clip semantics over already-existing sidecars;
  ❌ Reqs 1 / 6 / 8 "in-actor only" remains true unless coordinator can attach
  to direct sidecar paths read-only.

### Option B: Extract real audio pipeline into `LiveCaptureSession`

- Do A first, then C4: relocate the existing direct pipeline body
  (`Mic.swift:80-585`, `SysAudio.swift:107-525`) into `LiveCaptureSession`;
  direct subcommands delegate.
- Daemon `ensure` then opens a real source-owner capture.
- **Trade-offs**: ✅ daemon truly meets Reqs 1, 4.4, 6.x, 8.x, 9.1 end-to-end;
  ❌ touches the most safety-critical code path (live capture, TCC, recovery);
  ❌ rollback risk — direct smoke must pass byte-identical before merge;
  ❌ requires installed live capture to be paused or run against generated
  audio fixture only.

### Option C: Hybrid — control plane now, runtime later

- Land Option A as a first commit set under a new tasks.md "Phase 8 —
  Remediation" group.
- Defer Option B (C4) behind a feature gate: daemon attaches read-only to
  direct sidecar paths under `~/Documents/chronicle/live-*/<source>/` until
  the session refactor lands.
- **Trade-offs**: ✅ keeps the proven direct path untouched during rollout;
  ✅ shorter blast radius per merge; ❌ daemon "attaches" semantics is itself
  new design surface; ❌ doubles the number of code paths until B completes.

## Effort and Risk

| Group | Effort | Risk | Justification |
| --- | --- | --- | --- |
| C1 + C2 (wire RPC routes + real status projection) | M (3–5 days) | Medium | Existing coordinator + EventHub already typed; routing layer needs async bridge from sync `RPCServer.queue` to actor methods |
| C3 (publish to EventHub + durable JSONL) | S (1–2 days) | Low | Two-line change at coordinator append site + subscribe streaming over socket |
| C4 (extract real capture into `LiveCaptureSession`) | L (1–2 weeks) | High | Touches CoreAudio tap, SpeechAnalyzer, sinks, recovery; must preserve parity with 2026-05-13 receipts; live capture cohabitation risk |
| C5 (persist idempotency or delete abstraction) | S (1–2 days) | Low | Encode-on-disk replay store keyed by `(client_id, client_req_id, method)` |
| H1 (schema parity) | S (≤1 day) | Low | Mechanical trim of method/error registry |
| H2 (lease lifetime + `lease.*` RPC) | S (1–2 days) | Low | Existing `LeaseStore` already correct; only daemon-side wiring needed |
| H3 (real hard-kill simulator + test) | S (≤1 day) | Low | One-line fix in `Daemon.simulateHardKill`; new assertion |
| H4 (RPC round-trip behavior tests) | S (1–2 days) | Low | Required to validate C1; co-lands |
| H5 (CLI nest under `chronicle daemon`) | S (≤1 day) | Low | ArgumentParser nested `CommandConfiguration` |
| M1–M4 (dedup status projection / events / config payload / audioFormat validation) | S (≤1 day) | Low | Cleanup commits |
| L1, L2 (docs + examples) | XS | Low | Docs only |

Total to converge on Option A: **M, ~1 week**. Total to converge on Option B
including C4: **XL, ~3 weeks**.

## Recommendations for Design Phase

- **Preferred approach**: Option C. Land Option A as Phase 8 remediation under
  the same Kiro spec, then schedule Option B (C4) as a follow-up that requires
  pausing installed live capture and running the 2026-05-13 parity smoke.
- **Key decisions to reaffirm in design**:
  - RPC server is sync `DispatchQueue` today; choose whether to keep that and
    bridge to actors via `Task` + semaphore, or rewrite the listener as an
    `AsyncSequence`-driven loop. Cite `RPCTransport.swift:81-110`.
  - Decide whether `IdempotencyStore` is durable across daemon restarts (Req
    2.2 + 9.3 interaction) or in-memory only. Spec language reads durable to
    most readers; current code reads in-memory.
  - Decide whether marker / clip events go through `DaemonEventLog` (durable)
    or remain coordinator-local; design Section "Coordinator and Capture
    Layer" implies durable but coordinator code does not write them.
  - Decide CLI shape (Option H5) before any new release that ships these
    subcommands publicly.

- **Research items to carry forward**:
  - Streaming JSONL over the existing `RPCServer` connection requires keeping
    `clientFD` open after the first response; `accept`/`read`/`write` loop is
    currently one-shot. Investigate `DispatchIO` vs. raw `read` loop on Darwin
    sockets with non-blocking reads.
  - `flock(2)` cross-process behavior on Darwin for the duplicate-owner gate is
    only smoke-validated. Decide whether a `Process`-spawned Swift Testing case
    is worth the harness complexity.
  - `chronicle daemon-run` needs a survivable run command if it is to host
    actual capture. Today it sleeps and returns on SIGINT/SIGTERM; once C4
    lands, this must own bounded finalization timers (Req 9.2) plus heartbeat
    emitter (Req 8.1).
  - The direct rollback smoke `scripts/smoke-sysaudio-diarize.sh` cannot run
    while the installed live capture is active; need a fixture path that uses
    ALAC-in-CAF playback instead of system output to validate Req 10.4 without
    pausing operator capture.

## Document Status

- Method: post-implementation gap analysis, requirements re-checked against
  current code, prior architect-review evidence retained as cited findings.
- Files cited: `Sources/Chronicle/Core/Daemon/*.swift`,
  `Sources/Chronicle/Core/Capture/LiveCaptureSession.swift`,
  `Sources/Chronicle/Subcommands/{Mic,SysAudio,DaemonCommands}.swift`,
  `Sources/Chronicle/Chronicle.swift`, `Tests/ChronicleTests/Daemon/*.swift`,
  `scripts/smoke-daemon-{kill9,integration}.sh`.

## Next Steps

- Refresh `tasks.md` with a "Phase 8 — Remediation" section that mirrors the
  CRITICAL / HIGH / MEDIUM groups above. The current tasks.md checklist
  faithfully recorded every task as `[x]` because the acceptance criteria as
  written passed against in-actor surfaces; the new tasks should harden the
  RPC and runtime surfaces without rewinding existing receipts.
- Run `/kiro design agent-safe-capture-daemon-control-plane` to revise the
  design's RPC server contract (sync-to-actor bridge, EventHub publication
  site, durable idempotency policy) before opening Phase 8 implementation
  tasks.
- 2026-05-28 update: operator paused installed live capture. C4 (real audio
  extraction in `LiveCaptureSession`) is unblocked. Re-instate the guard only
  if the operator restarts `/Applications/chronicle.app/Contents/MacOS/chronicle
  {mic,sysaudio}` before Phase 8 completes.
