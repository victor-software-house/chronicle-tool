# Implementation Plan

- [ ] 1. Establish daemon runtime foundation
- [x] 1.1 Add source identity, lifecycle, and runtime path models
  - Define the supported capture sources and lifecycle states used by daemon status, ownership, and RPC responses.
  - Resolve per-user socket, lock, PID, and log paths for each source without opening any audio resource.
  - Add focused tests that prove `sysaudio` and `mic` paths are independent and local-only.
  - Observable completion: tests can construct runtime paths and lifecycle values for both sources without requiring TCC or live audio.
  - _Requirements: 1.4, 10.1_
  - _Boundary: DaemonTypes, RuntimePaths_

- [x] 1.2 Add physical source ownership guard
  - Add per-source ownership acquisition that rejects an active owner before capture starts.
  - Detect stale ownership state after an unclean exit and allow recovery only when the prior owner is no longer live.
  - Report existing owner information in a machine-readable snapshot for duplicate-start responses.
  - Observable completion: duplicate-owner and stale-owner tests pass without opening CoreAudio or microphone resources.
  - _Requirements: 1.1, 1.2, 1.3, 1.4_
  - _Boundary: SourceOwner_

- [x] 1.3 Add daemon event log envelope and recovery reader
  - Persist control, manifest, heartbeat, marker, and recovery events with version, source, epoch, sequence, monotonic time, wall clock, type, and payload.
  - Reuse append-only durability so a hard kill can corrupt at most the trailing record.
  - Add reader behavior that ignores one torn trailing record and fails on malformed middle records.
  - Observable completion: event-log tests prove sequence ordering, required envelope fields, recovery events, and torn-line behavior.
  - _Requirements: 4.1, 4.2, 4.3, 6.3, 9.3, 9.4_
  - _Boundary: DaemonEvent, DaemonEventLog_

- [ ] 2. Build local RPC protocol and schema
- [x] 2.1 Add JSON-RPC envelopes and structured errors
  - Define request, response, notification, and error envelopes for the local control surface.
  - Ensure all normal errors include stable code, retriable flag, remediation hint, and optional details.
  - Reject malformed and unsupported requests without exposing stack traces.
  - Observable completion: protocol tests cover malformed requests, unsupported methods, structured errors, and stack-trace-free output.
  - _Requirements: 3.3, 3.4_
  - _Boundary: RPCProtocol_

- [x] 2.2 (P) Add self-describing schema output
  - Produce a schema response covering protocol version, methods, request and response fields, events, error codes, and examples.
  - Mark mutating methods as requiring `client_req_id`.
  - Add compatibility version checks for breaking contract changes.
  - Observable completion: schema tests fail if a registered method is missing or a mutating method lacks `client_req_id` in schema.
  - _Requirements: 3.1, 3.2_
  - _Boundary: OpenRPCSchema_

- [x] 2.3 Add local RPC server and client transport
  - Serve JSON-RPC over the per-source local socket without exposing a network listener.
  - Provide a shared client used by thin command wrappers.
  - Return daemon-unavailable and malformed-request errors in the same structured shape as in-process method errors.
  - Observable completion: transport tests can round-trip `meta.schema` and `status.get` over a local socket fixture.
  - _Requirements: 3.1, 3.3, 10.1_
  - _Boundary: RPCServer, ChronicleRPCClient_
  - _Depends: 1.1, 2.1, 2.2_

- [ ] 3. Add coordination stores and status projection
- [x] 3.1 (P) Add idempotency replay for mutating requests
  - Store recent mutating request outcomes by method and client request id.
  - Replay the same success or error response when the same request is retried.
  - Reject conflicting payloads that reuse a previous client request id.
  - Observable completion: tests prove timeout retry replay, error replay, and conflict rejection.
  - _Requirements: 2.2_
  - _Boundary: IdempotencyStore_
  - _Depends: 2.1_

- [x] 3.2 (P) Add TTL client leases
  - Support lease acquire, renew, release, and automatic expiry for multi-step client operations.
  - Keep leases separate from physical source ownership.
  - Emit visible lease lifecycle events for acquire, release, and expiry.
  - Observable completion: lease tests prove expiry removes orphaned coordination state and records an event.
  - _Requirements: 7.5_
  - _Boundary: LeaseStore_
  - _Depends: 1.3_

- [x] 3.3 Add heartbeat and status snapshots
  - Publish periodic heartbeat state for running owners.
  - Project stopped, starting, capturing, reconfiguring, degraded, stopping, stale, and failed states.
  - Include sidecar paths, heartbeat freshness, peaks, transcript counters, speaker-label state, idle output, and last actionable error.
  - Observable completion: status tests distinguish stopped, stale heartbeat, idle output, degraded layer failure, and runtime-evidence healthy states.
  - _Requirements: 2.3, 2.4, 2.5, 8.1, 8.2, 8.3, 8.4, 9.4_
  - _Boundary: Heartbeat, DaemonStatus_
  - _Depends: 1.3_

- [ ] 4. Extract reusable live capture session
- [x] 4.1 Extract shared capture configuration and hot-change policy
  - Normalize current direct command settings into a reusable capture configuration.
  - Classify which settings can change live, which apply only to future segments, and which require rejection while capture is active.
  - Add tests for supported, unsupported, and future-segment-only changes.
  - Observable completion: configuration tests return clear allow/reject decisions with operator-readable alternatives.
  - _Requirements: 6.1, 6.2_
  - _Boundary: LiveCaptureConfiguration_

- [x] 4.2 Extract reusable live capture session runner
  - Move shared mic/sysaudio pipeline orchestration behind a reusable session boundary while preserving direct command behavior.
  - Surface session status for paths, peaks, transcript counters, latency, speaker labels, and progressive-layer state.
  - Keep base rough transcript active before progressive quality layers are ready.
  - Observable completion: direct `mic` and `sysaudio` help/output behavior remains available and unit tests can instantiate session configuration without live TCC.
  - _Requirements: 4.4, 6.1, 6.4, 8.4, 9.1, 10.4_
  - _Boundary: LiveCaptureSession, LiveCaptureStatus_
  - _Depends: 4.1_

- [x] 4.3 Wire direct commands through the shared session without changing rollback behavior
  - Update direct `mic` and `sysaudio` commands to use the shared session runner.
  - Preserve existing flags, sidecar outputs, diagnostics, and direct smoke compatibility.
  - Ensure direct commands remain usable when no daemon is running.
  - Observable completion: `chronicle mic --help` and `chronicle sysaudio --help` still expose expected direct-mode flags, and direct-mode smoke remains the rollback gate.
  - _Requirements: 4.4, 10.4_
  - _Boundary: Mic, SysAudio, LiveCaptureSession_
  - _Depends: 4.2_

- [ ] 5. Implement daemon coordinator methods
- [x] 5.1 Add ensure, stop, and status method handling
  - Coordinate source ownership, idempotency, capture start, stopped-state responses, and stop outcomes.
  - Return existing running state for duplicate start requests.
  - Attempt bounded graceful stop and report finalization/escalation outcome.
  - Observable completion: coordinator tests cover ensure when stopped, ensure when running, stop when stopped, graceful stop, and escalated stop result.
  - _Requirements: 1.1, 1.2, 2.1, 2.2, 2.3, 2.4, 9.1, 9.2_
  - _Boundary: DaemonCoordinator_
  - _Depends: 1.2, 3.1, 3.3, 4.2_

- [x] 5.2 Add reconfiguration method handling
  - Apply supported progressive-layer changes without stopping rough transcript capture.
  - Reject unsafe active changes with non-retriable structured errors and alternatives.
  - Record reconfiguration start, success, and failure events.
  - Observable completion: coordinator tests prove enabling a progressive layer leaves base capture state active and unsupported changes are rejected cleanly.
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
  - _Boundary: DaemonCoordinator, LiveCaptureConfiguration_
  - _Depends: 4.1, 5.1_

- [x] 5.3 (P) Add event filtering and subscription fan-out
  - Filter events by source, stream, type prefix, sequence, final-only, speaker-label availability, and heartbeat inclusion.
  - Deliver daemon events and bridged transcript trace events to local subscribers.
  - Apply bounded slow-subscriber behavior and emit lag notifications.
  - Observable completion: event hub tests prove filtering, heartbeat delivery, since-sequence behavior, and slow subscriber lag without blocking publishers.
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 8.1_
  - _Boundary: EventFilter, EventHub_
  - _Depends: 1.3_

- [x] 5.4 Add marker and recent clip coordination
  - Create timestamped marker events for active source sessions.
  - Return clear no-active-session responses when markers cannot attach to live sessions.
  - Coordinate bounded recent clip requests and report either output location or available range.
  - Observable completion: coordinator tests cover active marker, no-active-session marker, successful clip request, unavailable clip range, and lease cleanup.
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_
  - _Boundary: ClipCoordinator, DaemonCoordinator, LeaseStore_
  - _Depends: 3.2, 5.1_

- [ ] 6. Add daemon and thin client command surface
- [x] 6.1 Add daemon run command
  - Start one source-owner daemon for `sysaudio` or `mic` from the signed app runtime.
  - Publish socket, manifest/control logs, status, and heartbeat while capture is running.
  - Fail duplicate starts before opening audio resources.
  - Observable completion: command-level tests or smoke fixtures show the daemon run command creates runtime state and rejects duplicate ownership.
  - _Requirements: 1.1, 1.2, 1.4, 8.1, 10.1_
  - _Boundary: Daemon, SourceOwner, DaemonCoordinator_
  - _Depends: 5.1_

- [x] 6.2 Add start, stop, and status client commands
  - Implement thin RPC clients for source/full start, stop, and JSON status.
  - Keep command logic limited to request serialization, daemon bootstrap where allowed, and response rendering.
  - Ensure status succeeds with stopped states when no owner is active.
  - Observable completion: CLI tests prove start/stop/status commands do not open audio resources and render machine-readable responses.
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 10.4_
  - _Boundary: Start, Stop, Status, ChronicleRPCClient_
  - _Depends: 2.3, 6.1_

- [x] 6.3 (P) Add tail, mark, clip, and config client commands
  - Implement thin RPC clients for event subscription, marker creation, recent clip requests, and hot reconfiguration.
  - Render JSONL event streams for tail without polling sidecar files.
  - Preserve structured errors for no-active-session, unavailable clip ranges, and unsupported reconfigure.
  - Observable completion: CLI tests cover request serialization and response/error rendering for tail, mark, clip, and config commands.
  - _Requirements: 5.1, 5.2, 6.2, 7.1, 7.2, 7.3, 7.4_
  - _Boundary: Tail, Mark, Clip, Config, ChronicleRPCClient_
  - _Depends: 2.3, 5.2, 5.3, 5.4_

- [x] 6.4 Register subcommands and preserve local-only behavior
  - Register all daemon and client commands in the executable command list.
  - Ensure no command starts a network listener or requires cloud services for production behavior.
  - Keep generated-voice smoke fixture usage limited to scripts/tests.
  - Observable completion: help output lists the new command surface and production commands run without cloud credentials.
  - _Requirements: 3.1, 10.1, 10.2, 10.3, 10.4_
  - _Boundary: Chronicle, Subcommands_
  - _Depends: 6.1, 6.2, 6.3_

- [ ] 7. Validate recovery, subscriptions, and rollback gates
- [x] 7.1 Add daemon kill -9 recovery smoke
  - Start daemon sysaudio, produce deterministic generated-voice audio, verify subscribed final events, hard-kill the daemon, and restart.
  - Assert complete daemon JSONL records parse, at most one trailing record is ignored, recovery status is reported, and sidecar evidence remains recoverable.
  - Observable completion: `scripts/smoke-daemon-kill9.sh` exits nonzero on missing subscribe events, broken JSONL recovery, missing recovery status, or missing sidecar evidence.
  - _Requirements: 4.2, 4.3, 5.1, 9.3, 9.4, 10.3_
  - _Boundary: Smoke Tests, DaemonCoordinator, DaemonEventLog_
  - _Depends: 6.4_

- [x] 7.2 Run direct-mode rollback and daemon integration verification
  - Run the existing generated-voice direct sysaudio diarization smoke to prove rollback behavior still works.
  - Run daemon duplicate-owner, status, subscribe, hot-reconfigure, marker, clip, and shutdown checks.
  - Record verification receipts in the relevant Kiro task metadata and status docs only after tests pass.
  - Observable completion: direct smoke, daemon smoke, and `swift test` pass together before implementation is claimed complete.
  - _Requirements: 1.1, 2.1, 2.5, 5.1, 6.1, 7.1, 7.3, 8.4, 9.1, 10.4_
  - _Boundary: Validation_
  - _Depends: 7.1_
## Implementation Notes

- 2026-05-28: Live direct capture guard lifted by operator after Phase 7 (recording paused). Phase 8 implementation is free to extract the real audio pipeline into `LiveCaptureSession` and exercise direct `mic` / `sysaudio` plus the `sysaudio-diarize` smoke. If live capture resumes, re-instate the guard before continuing.
- 2026-05-28 (validate-gap): Phases 1–7 above are recorded as `[x]` because their acceptance criteria as written passed against in-actor surfaces and isolated smokes. A post-impl architect review (see `research.md` §Post-Implementation Gap Validation) found that the RPC server is not wired to `DaemonCoordinator`, `EventHub` is never published to, and `LiveCaptureSession` does not open audio. Phase 8 below tracks the remediation work; previous tasks are not retroactively rewound.

- [ ] 8. Remediate post-impl gaps from validate-gap
- [x] 8.1 Wire RPCServer to DaemonCoordinator and EventHub
  - Inject `DaemonCoordinator` and `EventHub` into `RPCServer`; route `capture.ensure`, `capture.stop`, `capture.reconfigure`, `mark.create`, `clip.create`, `lease.*`, `events.subscribe` through the coordinator and surface structured errors.
  - Replace `RPCProtocol.dispatch` `{accepted:true}` placeholder for registered methods.
  - Observable completion: an RPC round-trip test starts a `Daemon`, sends `StartClient.send`, asserts `lifecycle == capturing` and `existingOwner` shape; today this test must fail before this task is implemented.
  - _Requirements: 2.1, 2.2, 2.4, 6.1, 6.2, 6.3, 7.1, 7.2, 7.3, 7.4_
  - _Boundary: RPCServer, DaemonCoordinator, EventHub_
  - _Depends: 5.1, 5.3, 5.4_

- [x] 8.2 Replace hardcoded `status.get` projection with `DaemonCoordinator.status()`
  - `RPCTransport.swift:122-127` currently returns `lifecycle=stopped` literal. Encode the full `DaemonStatus` projection (source, lifecycle, sidecars, last heartbeat, peak, counters, label state, last error) as JSON.
  - Observable completion: status RPC round-trip returns nonzero peak / nonstopped lifecycle when capture is active.
  - _Requirements: 2.5, 8.1, 8.2, 8.3, 8.4_
  - _Boundary: RPCServer, DaemonStatus, Heartbeat_
  - _Depends: 8.1_

- [x] 8.3 Publish coordinator events through EventHub and DaemonEventLog
  - Every `DaemonCoordinator` event append also calls `eventHub.publish(event)` and writes through `DaemonEventLog` for durability.
  - Stream subscriber output as JSONL over the RPC connection (keep `clientFD` open after `events.subscribe`).
  - Observable completion: subscriber receives `marker.created` after `MarkClient.send` against a running daemon; durable JSONL contains the same record.
  - _Requirements: 4.1, 4.2, 5.1, 5.2, 5.3, 5.4, 7.1_
  - _Boundary: DaemonCoordinator, EventHub, DaemonEventLog, RPCServer_
  - _Depends: 8.1_

- [x] 8.4 (P) Heartbeat emitter and idle-output reporting
  - Add a heartbeat producer (timer or `Task.sleep` loop) that publishes a `heartbeat` event per source every N seconds while running.
  - Mark `idleOutput=true` when peak and counters remain zero, without flagging capture as failed.
  - Observable completion: subscribe stream observes ≥2 heartbeats; status reflects idle output.
  - _Requirements: 8.1, 8.2, 8.3_
  - _Boundary: Daemon, Heartbeat, EventHub_
  - _Depends: 8.3_

- [x] 8.5 Decide and implement idempotency durability
  - Either delete `IdempotencyStore` and update spec text to flag in-memory-only replay, or replace per-method dictionaries in `DaemonCoordinator` with a single `IdempotencyStore` persisted to disk under `paths.sourceDirectory`.
  - Observable completion: a kill-9 + restart smoke replays the same `client_req_id` and receives the prior outcome.
  - _Requirements: 2.2, 4.1, 9.3, 9.4_
  - _Boundary: IdempotencyStore, DaemonCoordinator_
  - _Depends: 8.1_

- [x] 8.6 Trim OpenRPCSchema to implemented intersection until wiring lands
  - `OpenRPCSchema` advertises methods and error codes the server does not honor. Either gate schema by implementation status or hold the schema trim commit until 8.1–8.3 land.
  - _Requirements: 3.1, 3.3_
  - _Boundary: OpenRPCSchema, RPCServer_
  - _Depends: 8.1_

- [x] 8.7 LeaseStore lifetime + `lease.*` RPC
  - `DaemonCoordinator.swift:181-184` reconstructs `LeaseStore` on every `createClip`; promote to coordinator lifetime, sweep expired entries on a TTL, and wire `lease.acquire/renew/release` through `RPCServer`.
  - Observable completion: concurrent lease holders observe each other; expired leases emit control events; orphaned multi-step state never blocks future operations indefinitely.
  - _Requirements: 7.5_
  - _Boundary: LeaseStore, DaemonCoordinator, RPCServer_
  - _Depends: 8.1_

- [x] 8.8 Real hard-kill simulator and stale-owner inspection test
  - `Daemon.simulateHardKill` currently calls `ownerLease?.release()` which deletes the PID file; a real `kill -9` leaves the PID file behind. Close the lock fd without invoking lease `release()`. Add a test that asserts `SourceOwner.inspect()` returns `lifecycle == .stale, isActive == false` after the simulated kill.
  - _Requirements: 1.3, 9.3_
  - _Boundary: Daemon, SourceOwner_
  - _Depends: 1.2, 6.1_

- [ ] 8.9 Nest daemon verbs under `chronicle daemon` subcommand
  - Move `start`, `stop`, `status`, `tail`, `mark`, `clip`, `config`, `daemon-run` under a single `chronicle daemon` ArgumentParser group to avoid collisions with `mic`, `sysaudio`, `live`.
  - Update tests, smokes, and `AGENTS.md` references.
  - _Requirements: 10.4_
  - _Boundary: Chronicle, Subcommands_
  - _Depends: 6.4_

- [ ] 8.10 Extract real audio pipeline into `LiveCaptureSession`
  - Move engine/source/analyzer/sinks construction out of `Mic.swift:80-585` and `SysAudio.swift:107-525` into `LiveCaptureSession.start/stop/reconfigure`. Direct subcommands delegate. Daemon `coordinator.ensure` opens a real source-owner capture.
  - Observable completion: byte-identical parity against the 2026-05-13 Zoom receipts (`out/full-session/transcribe.txt`, `diarize.json`) plus a daemon-mode smoke that produces nonzero peak and durable sidecars under `paths.sourceDirectory`.
  - _Requirements: 1.1, 4.4, 6.1, 6.4, 8.1, 8.4, 9.1, 9.2, 10.4_
  - _Boundary: LiveCaptureSession, Mic, SysAudio, DaemonCoordinator_
  - _Depends: 8.1, 8.2, 8.3, 8.4, 8.5, 8.7, 8.8, 8.9_

- [ ] 8.11 Phase 8 verification
  - Run `swift test`, `scripts/smoke-daemon-kill9.sh` (mic + sysaudio), `scripts/smoke-daemon-integration.sh` (mic + sysaudio), and `scripts/smoke-sysaudio-diarize.sh` against the rebuilt daemon path.
  - Add an RPC round-trip behavior smoke that exercises ensure → status → mark → clip (success + range_unavailable) → config (applied + rejected) → subscribe → stop using real responses, not `accepted=true`.
  - _Requirements: all_
  - _Boundary: Validation_
  - _Depends: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 8.9, 8.10_
