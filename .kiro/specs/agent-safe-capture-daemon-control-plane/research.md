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
