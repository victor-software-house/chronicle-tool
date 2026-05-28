# Requirements Document

## Introduction

Chronicle currently has a proven direct live capture path for system audio and
microphone sources, but safe 24/7 operation needs a control plane that lets many
operator tools and agents observe or control capture without starting duplicate
physical capture processes. This feature establishes one capture owner per
physical source, a self-describing local control surface, retry-safe mutations,
subscribe-based event consumption, and crash recovery expectations while
preserving the current near-real-time transcript behavior.

## Boundary Context

- **In scope**: source-owner lifecycle for `sysaudio` and `mic`, machine-readable
  status, local control commands, event subscription, markers, recent clip
  requests, hot reconfiguration safety gates, heartbeats, and crash recovery
  behavior.
- **Out of scope**: replacing the current CoreAudio tap backend, merging mic and
  sysaudio into one raw transcription stream, remote/network control, cloud
  transcription in production capture, retention/pruning policy, speaker identity
  memory, and launch-at-login packaging.
- **Adjacent expectations**: the existing direct `mic` and `sysaudio` commands
  remain a rollback path; existing sidecars remain the durable transcript/audio
  evidence; the implemented `sysaudio-runtime-hardening` behavior is treated as
  the runtime baseline for system-audio capture.

## Requirements

### Requirement 1: Single Source Ownership

**Objective:** As the Chronicle operator, I want only one capture owner for each
physical source, so that agents cannot accidentally duplicate taps, microphones,
or sidecar writers.

#### Acceptance Criteria

1. When a capture owner for a source is already running, the Chronicle control
   plane shall reject a second owner for the same source before it starts live
   capture.
2. When a duplicate owner is rejected, the Chronicle control plane shall report
   the existing owner state and an operator-readable remediation without
   interrupting the active capture.
3. If stale ownership state remains after an unclean exit, then the Chronicle
   control plane shall distinguish stale state from an active owner before
   allowing a new owner to start.
4. The Chronicle control plane shall maintain separate ownership state for
   `sysaudio` and `mic` so each source can run independently.

### Requirement 2: Idempotent Start, Stop, and Status Commands

**Objective:** As an agent client, I want safe start, stop, and status commands,
so that retries and repeated calls do not create duplicate capture or ambiguous
state.

#### Acceptance Criteria

1. When a client requests capture start for a source that is already running, the
   Chronicle control plane shall return the existing running state instead of
   starting a duplicate owner.
2. When a client repeats the same mutating request after a timeout, the Chronicle
   control plane shall return the same outcome without applying the mutation a
   second time.
3. When a client requests status and no capture owner is running, the Chronicle
   control plane shall return a successful stopped-state response for each known
   source.
4. When a client requests stop for a source that is not running, the Chronicle
   control plane shall return an idempotent stopped-state response.
5. The Chronicle control plane shall include enough state in status responses for
   clients to identify the source, lifecycle state, sidecar locations, last
   heartbeat, last observed audio peak, transcript counters, speaker-label state,
   and last actionable error.

### Requirement 3: Self-Describing Local Control Surface

**Objective:** As an agent client, I want the control surface to describe itself,
so that I can discover supported commands, events, errors, and compatibility
without reading repository source code.

#### Acceptance Criteria

1. When a client asks for the control schema, the Chronicle control plane shall
   return the protocol version, supported methods, request fields, response
   fields, event types, error codes, and examples.
2. When a method changes incompatibly, the Chronicle control plane shall expose a
   changed compatibility version so clients can detect the mismatch.
3. If a client sends an unsupported method or malformed request, then the
   Chronicle control plane shall return a structured error with a stable code,
   retriable flag, and remediation hint.
4. The Chronicle control plane shall not expose stack traces or internal debug
   dumps in normal client error responses.

### Requirement 4: Durable Versioned Event Records

**Objective:** As a downstream recovery or review tool, I want every committed
event to carry durable ordering and time metadata, so that sessions can be
audited and reconstructed after daemon restarts or crashes.

#### Acceptance Criteria

1. When the control plane writes a durable event, the Chronicle control plane
   shall include a schema version, source, daemon epoch, per-stream sequence,
   monotonic time, wall-clock time, and event type.
2. When a capture owner restarts after an unclean exit, the Chronicle control
   plane shall record a new epoch and a recovery event before continuing normal
   capture events.
3. If a durable event stream contains a torn trailing record after a hard kill,
   then the Chronicle control plane shall ignore at most the torn trailing record
   and preserve all complete records.
4. The Chronicle control plane shall preserve existing transcript and audio
   sidecars as user-visible evidence for the session.

### Requirement 5: Subscribe-Based Event Consumption

**Objective:** As an agent client, I want filtered event subscriptions, so that I
can follow live capture without polling files or parsing stderr.

#### Acceptance Criteria

1. When a client subscribes to final transcript events for a source, the
   Chronicle control plane shall stream matching final events for that source.
2. When a client subscribes with filters for source, event type, sequence, or
   speaker-label availability, the Chronicle control plane shall only deliver
   events matching those filters.
3. While capture is running and no matching transcript event is available, the
   Chronicle control plane shall provide liveness information through heartbeat
   events or a clear stream termination.
4. If a subscriber falls behind the live event stream, then the Chronicle control
   plane shall apply a documented lag policy and report that lag to the
   subscriber without blocking capture.

### Requirement 6: Safe Live Reconfiguration

**Objective:** As the Chronicle operator, I want supported settings to change
without restarting capture, so that agents can adjust quality layers while the
rough transcript remains live.

#### Acceptance Criteria

1. When a client enables or disables a supported progressive quality layer, the
   Chronicle control plane shall keep rough transcript capture active during the
   change.
2. When a requested setting cannot be changed safely while capture is active, the
   Chronicle control plane shall reject the change with a non-retriable error and
   an operator-readable alternative.
3. When a live reconfiguration begins and completes, the Chronicle control plane
   shall record user-visible control events for both outcomes.
4. If reconfiguration of a progressive layer fails, then the Chronicle control
   plane shall keep the base capture session running when possible and report the
   layer failure separately from source capture health.

### Requirement 7: Markers and Recent Clips

**Objective:** As an operator or agent, I want to add markers and request recent
clips, so that important moments can be identified or exported without stopping
capture.

#### Acceptance Criteria

1. When a client creates a marker during active capture, the Chronicle control
   plane shall append a timestamped marker event associated with the active
   source sessions.
2. When a client creates a marker while no source is active, the Chronicle
   control plane shall return a clear no-active-session response without creating
   misleading transcript evidence.
3. When a client requests a recent clip window that is available in sidecars, the
   Chronicle control plane shall produce a bounded export or report where the
   export can be found.
4. If a requested clip window is outside retained sidecar data, then the
   Chronicle control plane shall return a structured error that states what time
   range is available.
5. While a multi-step marker or clip operation is active, the Chronicle control
   plane shall prevent orphaned client coordination state from blocking future
   operations indefinitely.

### Requirement 8: Heartbeats and Health Reporting

**Objective:** As a supervisor or agent, I want reliable heartbeats and health
state, so that stale daemons, idle output, and real failures are distinguishable.

#### Acceptance Criteria

1. While a capture owner is running, the Chronicle control plane shall publish
   periodic heartbeats that identify the source and current lifecycle state.
2. When system audio capture is active but no app is producing audible output,
   the Chronicle control plane shall report idle output separately from capture
   failure.
3. If heartbeat freshness expires, then the Chronicle control plane shall report
   the source as stale or unavailable until a live owner is verified.
4. When live capture observes nonzero audio and transcript output, the Chronicle
   control plane shall treat runtime evidence as the authority for capture
   health.

### Requirement 9: Crash Recovery and Shutdown Behavior

**Objective:** As the Chronicle operator, I want captures to recover after
termination or crashes, so that 24/7 recording does not depend on graceful exits.

#### Acceptance Criteria

1. When the capture owner receives a normal stop request, the Chronicle control
   plane shall attempt graceful shutdown and report whether finalization
   completed.
2. If graceful shutdown does not complete within the bounded stop window, then
   the Chronicle control plane shall escalate shutdown and preserve already
   committed sidecar evidence.
3. When the capture owner is killed abruptly, the Chronicle control plane shall
   leave complete durable event records parseable and recent audio recoverable
   from existing sidecars or scratch evidence.
4. When capture restarts after abrupt termination, the Chronicle control plane
   shall report the previous termination and recovery status in machine-readable
   state.

### Requirement 10: Privacy and Local-Only Operation

**Objective:** As the Chronicle operator, I want the control plane to remain
local-first, so that capture control does not create a new network or cloud
exposure.

#### Acceptance Criteria

1. The Chronicle control plane shall expose control only to local clients on the
   operator machine.
2. The Chronicle control plane shall not require cloud services for production
   capture, status, subscription, marker, clip, or reconfiguration behavior.
3. Where generated cloud voices are used for smoke testing, the Chronicle project
   shall keep that dependency outside production capture behavior.
4. The Chronicle control plane shall preserve the existing direct live capture
   commands as a local rollback path until the daemon behavior is explicitly
   accepted.
