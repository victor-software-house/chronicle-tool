---
title: "Speaker identity memory"
prd: PRD-002
status: Draft
owner: "Victor"
issue: "N/A"
date: 2026-05-17
version: "1.0"
---

# PRD: Speaker identity memory

---

## 1. Problem & Context

PRD-001 FR-4 gives Chronicle session-local speaker diarization: `chronicle mic --diarize` and `chronicle sysaudio --diarize` attach labels such as `S0` and `S1` to transcript results by aligning SpeechAnalyzer audio ranges with a Sortformer diarization timeline. Those labels answer "which parts of this capture sound like the same speaker?" within one run.

They do not answer "is this Victor from yesterday?" Labels reset every run, carry no human identity, and are not durable across sessions. This is correct for FR-4 but incomplete for long-running Chronicle use-cases: recurring meetings, 24/7 capture, and post-hoc search need stable, opt-in speaker identities such as `Victor`, `Client`, or `Unknown-3` while preserving the existing `S0/S1` trace semantics.

Speaker identity memory is higher-risk than diarization because it stores biometric-like voice embeddings. This PRD therefore treats identity as an explicit opt-in layer on top of diarization, not as a default behavior. The first implementation must be local-only, deletable, auditable, thresholded, and conservative: uncertain matches stay unknown instead of guessing.

Related current code:

* `Sources/Chronicle/Core/Diarize/StreamingDiarizer.swift` — streaming Sortformer diarization and session-local `speakerId` lookup.
* `Sources/Chronicle/Core/Audio/PCMFloatConverter.swift` — PCM normalization to 16 kHz mono float.
* `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift` — additive trace schema that currently stores `speakerId` but no persistent identity fields.
* `Sources/Chronicle/Core/Sinks/FinalsAppendSink.swift` — final transcript rendering with `[Sx]` prefixes.
* `Sources/Chronicle/Subcommands/Mic.swift` and `Sources/Chronicle/Subcommands/SysAudio.swift` — live command wiring for `--diarize`.
* `Sources/Chronicle/Subcommands/Merge.swift` — chronological merge renderer that already preserves `speakerId`.

---

## 2. Goals & Success Metrics

| Goal                              | Metric                                                | Target                                                                                                             |
| --------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| **Stable identity across runs**   | Same enrolled speaker recognized in separate captures | ≥ 90% of final speaker-attributed utterances get the correct enrolled identity on a controlled two-speaker fixture |
| **Conservative unknown handling** | False positive identity assignments on unknown voices | 0 false matches in the verification fixture; uncertain voices remain unknown                                       |
| **Local-first privacy**           | Network access during enroll/identify path            | 0 network calls after model files are installed                                                                    |
| **Operator control**              | Enroll/list/forget commands                           | All speaker records can be listed and deleted by name or id                                                        |
| **Trace compatibility**           | Existing PRD-001 trace consumers                      | Old `speakerId` behavior remains unchanged; new identity fields are optional/additive                              |

**Guardrails (must not regress):**

* `--diarize` without identity flags continues to emit only session-local `S0`, `S1`, ... labels.
* `chronicle merge` remains able to read PRD-001 `trace.jsonl` files with no identity fields.
* Identity matching must not block the live audio source callback.
* Unknown or low-confidence matches must not be rendered as a known speaker name.
* No cloud speaker recognition or external voiceprint service is allowed in the default implementation.

---

## 3. Users & Use Cases

### Primary: Chronicle operator

> As a Chronicle operator, I want to enroll my own voice and trusted recurring voices so that future transcripts show stable names instead of run-local `S0/S1` labels.

**Preconditions:** The operator has explicit consent to enroll each voice and has a clean speech sample for each speaker.

### Secondary: Transcript reviewer

> As a transcript reviewer, I want merged transcripts to preserve speaker names when confidence is high so that I can search and summarize meetings by person.

**Preconditions:** The source trace was captured with `--diarize --identify-speakers` and a local speaker store.

### Future: Post-hoc curator (enabled by this work)

> As a curator, I want to assign `S1` from an old trace to a known speaker after review so that future exports and re-renders use the corrected identity.

---

## 4. Scope

### In scope

1. **Local speaker enrollment CLI** — commands to enroll, list, inspect, and forget speaker records.
2. **Speaker embedding abstraction** — protocol around an on-device embedding backend so implementation can start with one model and later swap backends.
3. **Local speaker store** — durable store for speaker ids, display names, embedding vectors, enrollment metadata, and deletion.
4. **Live identity resolver** — map run-local `S0/S1` diarization clusters to enrolled speaker identities once enough evidence exists.
5. **Trace schema extension** — optional fields for identity id, display name, confidence, and match status.
6. **Finals and merge rendering** — show `[Name]` when an identity is accepted; otherwise keep `[Sx]` or `[Sx?]`.
7. **Tests and fixtures** — deterministic unit tests for store, thresholds, hysteresis, rendering, and fixture-backed smoke for a two-speaker enrolled/unknown case.

### Out of scope / later

| What                                                         | Why                                                         | Tracked in                   |
| ------------------------------------------------------------ | ----------------------------------------------------------- | ---------------------------- |
| Cloud speaker recognition                                    | Privacy and vendor lock-in risk; local-first required       | Future ADR if ever requested |
| Automatic enrollment of every unknown voice                  | High false-positive and consent risk                        | Future PRD                   |
| Global identity sync across machines                         | Needs encryption, key management, and consent model         | Future PRD                   |
| UI for correcting speakers interactively                     | Useful but separate from core CLI identity layer            | Future PRD                   |
| Legal/compliance policy text beyond local product guardrails | Requires product/legal review if shared beyond personal use | Future PRD/ADR               |

### Design for future (build with awareness)

Use protocols and additive trace fields so identity can evolve without rewriting FR-4:

* `SpeakerEmbeddingBackend` hides model choice.
* `SpeakerMemoryStore` hides storage format.
* `SpeakerIdentityResolver` maps `speakerId` clusters to optional identities, leaving diarization intact.
* Trace keeps `speakerId` as the stable session-local key and adds optional identity fields; downstream tools can ignore identity if they do not care.

---

## 5. Functional Requirements

### FR-1: Enroll a speaker locally

Chronicle provides a CLI command that turns one or more clean speech samples into a named speaker record. Enrollment stores embeddings locally with metadata and never uploads audio or embeddings.

**Acceptance criteria:**

```gherkin
Given /tmp/victor.wav contains at least 30 seconds of clean single-speaker speech
When the operator runs chronicle speakers enroll --name Victor --input /tmp/victor.wav
Then Chronicle creates a local speaker record with displayName "Victor"
And the record stores one or more embedding vectors
And Chronicle prints the speaker id and enrollment summary
And no network request is made during embedding extraction after model files exist locally
```

**Files:**

* `Sources/Chronicle/Subcommands/Speakers.swift` — new `chronicle speakers enroll` command group.
* `Sources/Chronicle/Core/Speakers/SpeakerEmbeddingBackend.swift` — embedding protocol and model-facing types.
* `Sources/Chronicle/Core/Speakers/SpeakerMemoryStore.swift` — local store interface.
* `Sources/Chronicle/Core/Speakers/FileSpeakerMemoryStore.swift` — first durable local implementation.

### FR-2: List, inspect, and forget speaker records

Operators can audit and delete stored identities. Delete must remove embeddings, metadata, and any store indexes for that speaker.

**Acceptance criteria:**

```gherkin
Given a local speaker store contains records for Victor and Sarah
When the operator runs chronicle speakers list
Then output includes each speaker id, display name, enrollment sample count, created date, and updated date
When the operator runs chronicle speakers forget --name Sarah
Then Sarah's embeddings and metadata are removed
And chronicle speakers list no longer shows Sarah
```

**Files:**

* `Sources/Chronicle/Subcommands/Speakers.swift` — `list`, `show`, and `forget` subcommands.
* `Sources/Chronicle/Core/Speakers/SpeakerMemoryStore.swift` — CRUD operations.
* `Tests/ChronicleTests/Speakers/SpeakerMemoryStoreTests.swift` — persistence and deletion tests.

### FR-3: Identify speakers during live capture

When `--identify-speakers` is enabled, Chronicle uses diarization segments and matching audio windows to resolve session-local speakers to enrolled identities. Matching is conservative and delayed until enough audio evidence exists for a speaker.

**Acceptance criteria:**

```gherkin
Given the local speaker store contains an enrolled speaker named Sarah
And chronicle sysaudio --diarize --identify-speakers is running
When Sarah speaks for at least 20 seconds in the captured audio
Then finals for Sarah are rendered with [Sarah] once confidence crosses the configured threshold
And finals before the threshold remain [S0] or [S0?]
And unknown speakers are not assigned Sarah's identity
```

**Files:**

* `Sources/Chronicle/Core/Speakers/SpeakerIdentityResolver.swift` — threshold, voting, and cluster-to-identity state.
* `Sources/Chronicle/Core/Speakers/SpeakerEvidenceBuffer.swift` — rolling audio evidence per run-local `speakerId`.
* `Sources/Chronicle/Subcommands/Mic.swift` — `--identify-speakers`, `--speaker-store`, and identity resolver wiring.
* `Sources/Chronicle/Subcommands/SysAudio.swift` — same for system-output capture.
* `Tests/ChronicleTests/Speakers/SpeakerIdentityResolverTests.swift` — matching, rejection, and hysteresis tests.

### FR-4: Extend trace schema additively

Trace events keep `speakerId` and add optional identity fields. Old traces remain readable. New traces carry enough metadata for merge/export to distinguish session-local cluster from persistent identity.

**Acceptance criteria:**

```gherkin
Given chronicle mic --diarize --identify-speakers is running with Victor enrolled
When a final transcript event is written after Victor is accepted
Then trace.jsonl includes speakerId "S0"
And speakerIdentityId is Victor's stable id
And speakerDisplayName is "Victor"
And speakerIdentityConfidence is present
And a PRD-001 trace without identity fields still decodes successfully
```

**Files:**

* `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift` — optional identity fields on `TraceEvent` and `record`.
* `Sources/Chronicle/Core/Sinks/TranscriptionSink.swift` — result payload gains optional speaker identity metadata.
* `Tests/ChronicleTests/Sinks/JSONLTraceSinkTests.swift` — decode old trace, encode identity fields.

### FR-5: Render accepted identities without hiding uncertainty

Finals and merge prefer accepted display names only when identity state is accepted. Unknown or low-confidence states keep the session-local label so readers can see uncertainty.

**Acceptance criteria:**

```gherkin
Given a trace contains final events for S0 accepted as Victor and S1 unresolved
When chronicle merge trace.jsonl is run
Then Victor's lines render with [Victor]
And unresolved S1 lines render with [S1?] or [S1]
And the output does not claim a name for S1
```

**Files:**

* `Sources/Chronicle/Core/Sinks/FinalsAppendSink.swift` — render accepted identity name over `speakerId`.
* `Sources/Chronicle/Subcommands/Merge.swift` — preserve and render identity metadata.
* `Tests/ChronicleTests/Sinks/FinalsAppendSinkTests.swift` — rendering precedence tests.
* `Tests/ChronicleTests/Subcommands/MergeTests.swift` — merge rendering with identity fields.

### FR-6: Provide post-hoc assignment hook

Chronicle supports a minimal post-hoc command to assign a run-local speaker from an existing trace to an enrolled speaker after review. This supports correction without making live matching overconfident.

**Acceptance criteria:**

```gherkin
Given trace.jsonl contains finals with speakerId S1 and no accepted identity
And the local store contains a speaker named George
When the operator runs chronicle speakers assign --trace trace.jsonl --speaker-id S1 --name George --output corrected.trace.jsonl
Then corrected.trace.jsonl contains speakerIdentityId and speakerDisplayName for S1 events
And original trace.jsonl is not overwritten unless --in-place is passed
```

**Files:**

* `Sources/Chronicle/Subcommands/Speakers.swift` — `assign` subcommand.
* `Sources/Chronicle/Core/Speakers/SpeakerTraceAssigner.swift` — trace rewrite service.
* `Tests/ChronicleTests/Speakers/SpeakerTraceAssignerTests.swift` — copy vs in-place behavior and identity field updates.

---

## 6. Non-Functional Requirements

| Category                   | Requirement                                                                                                      |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Privacy**                | Enrollment and identification are opt-in. No audio or embedding leaves the machine by default.                   |
| **Deletion**               | `forget` removes all embeddings and metadata for the selected speaker.                                           |
| **False-positive control** | Identity resolver defaults to unknown unless confidence and evidence duration thresholds pass.                   |
| **Latency**                | Identity matching must not block live source callbacks; matching may lag transcript output by up to 10 seconds.  |
| **Storage**                | Store format must be local, inspectable, and migration-friendly; no opaque global cache as sole source of truth. |
| **Compatibility**          | Existing PRD-001 traces and finals remain readable. New fields are optional/additive.                            |
| **Security**               | Store path must default under user-controlled app support data and avoid world-readable permissions.             |

---

## 7. Risks & Assumptions

### Risks

| Risk                                                          | Severity | Likelihood | Mitigation                                                                                      |
| ------------------------------------------------------------- | -------- | ---------- | ----------------------------------------------------------------------------------------------- |
| False identity assignment harms transcript trust              | High     | Medium     | Conservative thresholds, minimum evidence duration, unknown fallback, post-hoc correction path  |
| Voice embeddings are biometric-like sensitive data            | High     | High       | Explicit opt-in, local-only default, clear `forget`, file permissions, no auto-enroll           |
| Embedding model unavailable or too slow in Swift/CoreML       | Medium   | Medium     | Backend protocol; implementation plan must benchmark candidates before wiring CLI               |
| Diarization cluster drift maps one `Sx` to the wrong identity | Medium   | Medium     | Resolve identities over aggregated cluster evidence; require stable votes before accepting      |
| Multi-speaker enrollment sample pollutes an identity          | Medium   | Medium     | Validate enrollment sample with diarization; reject samples with more than one detected speaker |
| Trace schema changes break downstream tools                   | Medium   | Low        | Add optional fields only; keep `speakerId`; add old-trace decode tests                          |

### Assumptions

* A usable on-device speaker embedding model can be run from Swift/CoreML or wrapped behind a local executable without network calls.
* Enrollment samples will be operator-curated and at least 30 seconds for first implementation.
* PRD-001 diarization remains the source of session-local speaker segmentation; identity memory does not replace Sortformer.
* The first implementation targets personal/local Chronicle usage, not enterprise compliance.

---

## 8. Design Decisions

### D1: Identity is opt-in on top of diarization

**Options considered:**

1. Always identify when speaker store exists — convenient but surprising and risky.
2. Require `--identify-speakers` — explicit, scriptable, and safe.
3. Replace diarization labels with identity names by default — simpler output but hides uncertainty.

**Decision:** Require `--identify-speakers`; keep `--diarize` as the base capability.

**Rationale:** Persistent voice identity is materially different from session diarization. It needs explicit operator intent each run.

**Future path:** A config profile can later enable identity for trusted environments, but CLI behavior remains explicit.

### D2: Preserve `speakerId`; add identity metadata

**Options considered:**

1. Replace `speakerId` with display name — easy to read but loses session cluster information.
2. Keep `speakerId` and add optional identity fields — more fields but trace-safe.
3. Store identities only in rendered markdown — easy output but not machine-readable.

**Decision:** Keep `speakerId`; add optional `speakerIdentityId`, `speakerDisplayName`, `speakerIdentityConfidence`, and `speakerIdentityStatus`.

**Rationale:** `speakerId` is the bridge to diarization timing. Identity is an interpretation of that cluster, not the cluster itself.

### D3: Match identity by aggregated cluster evidence, not per final

**Options considered:**

1. Classify every final independently — fast to implement but label may flip line-by-line.
2. Aggregate audio evidence per `Sx` cluster and accept after threshold — stable and conservative.
3. Require post-hoc assignment only — safe but no live value.

**Decision:** Aggregate per run-local speaker cluster; accept only after enough evidence and confidence.

**Rationale:** Diarization already groups frames by speaker. Identity should use that grouping to reduce noise and avoid flicker.

### D4: Local inspectable store first

**Options considered:**

1. JSON document under Application Support — easiest to inspect but poor for vector search as records grow.
2. SQLite with embeddings serialized as blobs/arrays — durable, queryable, migration-friendly.
3. External vector DB — overkill and extra operational surface.

**Decision:** Prefer SQLite if implementation time permits; otherwise a versioned JSON store is acceptable for first prototype behind `SpeakerMemoryStore`.

**Rationale:** Store abstraction matters more than first format. Voice embeddings need migrations and deletion guarantees.

**Future path:** If speaker count grows, add vector index behind the same store protocol.

### D5: Enrollment rejects multi-speaker samples

**Options considered:**

1. Trust input blindly — simple but easy to poison a speaker profile.
2. Run diarization during enrollment and reject mixed samples — safer.
3. Ask operator to manually trim samples outside Chronicle — burdensome.

**Decision:** Run diarization check during enrollment when feasible; warn or reject if more than one speaker is detected.

**Rationale:** Bad enrollment data is the fastest path to false identity matches.

---

## 9. File Breakdown

| File                                                               | Change type | FR               | Description                                                               |
| ------------------------------------------------------------------ | ----------- | ---------------- | ------------------------------------------------------------------------- |
| `Sources/Chronicle/Chronicle.swift`                                | Modify      | FR-1, FR-2, FR-6 | Register `Speakers` command group.                                        |
| `Sources/Chronicle/Subcommands/Speakers.swift`                     | New         | FR-1, FR-2, FR-6 | `enroll`, `list`, `show`, `forget`, and `assign` commands.                |
| `Sources/Chronicle/Core/Speakers/SpeakerEmbeddingBackend.swift`    | New         | FR-1, FR-3       | Protocol and types for local embedding extraction.                        |
| `Sources/Chronicle/Core/Speakers/SpeakerMemoryStore.swift`         | New         | FR-1, FR-2, FR-3 | Store protocol for speaker records and embeddings.                        |
| `Sources/Chronicle/Core/Speakers/FileSpeakerMemoryStore.swift`     | New         | FR-1, FR-2       | First local durable store implementation.                                 |
| `Sources/Chronicle/Core/Speakers/SpeakerIdentityResolver.swift`    | New         | FR-3             | Cluster evidence aggregation, thresholding, accepted/unknown state.       |
| `Sources/Chronicle/Core/Speakers/SpeakerEvidenceBuffer.swift`      | New         | FR-3             | Rolling audio/evidence buffers per run-local `speakerId`.                 |
| `Sources/Chronicle/Core/Speakers/SpeakerTraceAssigner.swift`       | New         | FR-6             | Post-hoc trace identity assignment service.                               |
| `Sources/Chronicle/Core/Sinks/JSONLTraceSink.swift`                | Modify      | FR-4             | Add optional identity fields to `TraceEvent` and recording API.           |
| `Sources/Chronicle/Core/Sinks/TranscriptionSink.swift`             | Modify      | FR-4, FR-5       | Pass optional speaker identity metadata through sinks.                    |
| `Sources/Chronicle/Core/Sinks/FinalsAppendSink.swift`              | Modify      | FR-5             | Render accepted identity names before session-local labels.               |
| `Sources/Chronicle/Subcommands/Mic.swift`                          | Modify      | FR-3             | Wire `--identify-speakers`, store path, resolver, and evidence buffering. |
| `Sources/Chronicle/Subcommands/SysAudio.swift`                     | Modify      | FR-3             | Same identity wiring for system-output capture.                           |
| `Sources/Chronicle/Subcommands/Merge.swift`                        | Modify      | FR-5             | Preserve/render identity metadata.                                        |
| `Tests/ChronicleTests/Speakers/SpeakerMemoryStoreTests.swift`      | New         | FR-1, FR-2       | Store persistence, list, inspect, delete.                                 |
| `Tests/ChronicleTests/Speakers/SpeakerIdentityResolverTests.swift` | New         | FR-3             | Threshold, voting, unknown fallback, no flicker.                          |
| `Tests/ChronicleTests/Speakers/SpeakerTraceAssignerTests.swift`    | New         | FR-6             | Post-hoc assignment copy and in-place behavior.                           |
| `Tests/ChronicleTests/Sinks/JSONLTraceSinkTests.swift`             | Modify      | FR-4             | Old-trace decode and identity-field encode tests.                         |
| `Tests/ChronicleTests/Sinks/FinalsAppendSinkTests.swift`           | Modify/New  | FR-5             | Rendering precedence: identity, uncertain, session-local.                 |
| `Tests/ChronicleTests/Subcommands/MergeTests.swift`                | Modify      | FR-5             | Merge output with identity metadata.                                      |

---

## 10. Dependencies & Constraints

* Swift 6.2 / macOS 26 target remains unchanged.
* FluidAudio `SortformerDiarizer` remains the diarization source for session-local `speakerId`; identity memory does not replace it.
* Speaker embedding backend is intentionally unspecified until implementation planning benchmarks local candidates. Candidate must support local execution from Swift/CoreML or a controlled local process.
* Store must default to a user-local path such as `~/Library/Application Support/chronicle/speakers/` and use non-world-readable permissions.
* Enrollment and matching must be deterministic enough for tests with stub embeddings; real model smoke tests are separate verification.

---

## 11. Rollout Plan

1. Add `Core/Speakers` protocols, in-memory/file store, and stub embedding backend tests.
2. Add `chronicle speakers enroll/list/show/forget` using a deterministic fake backend in tests.
3. Research and benchmark at least one local embedding backend; record choice in an ADR if the model/runtime decision has durable consequences.
4. Add `SpeakerIdentityResolver` with threshold/hysteresis tests using synthetic embeddings.
5. Extend trace and sink APIs additively; verify old PRD-001 traces decode.
6. Wire `--identify-speakers` into `mic` and `sysaudio` behind `--diarize`.
7. Add merge/finals rendering behavior.
8. Run manual fixture smoke: enroll Sarah, leave George unknown; verify Sarah recognized and George remains unknown. Then enroll George and verify both recognized.
9. Update README/STATUS with privacy model, CLI examples, and receipts.

---

## 12. Open Questions

| #  | Question                                                                    | Owner  | Due                   | Status                                                          |
| -- | --------------------------------------------------------------------------- | ------ | --------------------- | --------------------------------------------------------------- |
| Q1 | Which local speaker embedding backend should Chronicle use first?           | Victor | Before implementation | Open                                                            |
| Q2 | Should first store be SQLite or versioned JSON?                             | Victor | Before FR-1           | Open                                                            |
| Q3 | What default similarity threshold avoids false positives on unknown voices? | Victor | During FR-3           | Open                                                            |
| Q4 | Should identities render as `[Victor]` or `[Victor/S0]` by default?         | Victor | During FR-5           | Open                                                            |
| Q5 | Should `assign` mutate existing trace in place or default to copy only?     | Victor | During FR-6           | **Resolved:** default copy; `--in-place` required for mutation. |

---

## 13. Related

| Issue                                               | Relationship                                                                           |
| --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `PRD-001` — Resilient multi-source chronicle daemon | Enables this PRD through FR-4 diarization, source-aware trace, and merge.              |
| `ADR-0001` — Modular pipeline architecture          | Governs protocol-oriented placement under `Core/` and thin subcommand veneers.         |
| `ADR-0003` — Locale resolution policy               | Pattern reference for conservative thresholding/hysteresis in live inference metadata. |
| Future ADR — speaker embedding backend selection    | Needed if backend choice introduces durable model/runtime constraints.                 |

---

## 14. Changelog

| Date       | Change        | Author |
| ---------- | ------------- | ------ |
| 2026-05-17 | Initial draft | Victor |

---

## 15. Verification (Appendix)

Post-implementation checklist:

1. `swift test` passes with deterministic fake embedding backend tests.
2. Old PRD-001 `trace.jsonl` fixture decodes with new `TraceEvent` optional identity fields absent.
3. Enroll Sarah from a clean sample; run `chronicle speakers list` and `show`; verify metadata and vector count.
4. Run `chronicle sysaudio --diarize --identify-speakers` against the Sarah + George fixture with only Sarah enrolled; verify Sarah lines render `[Sarah]` after threshold and George remains unknown/session-local.
5. Enroll George; rerun fixture; verify Sarah and George both render correctly with no false swaps.
6. Run `chronicle speakers forget --name Sarah`; verify Sarah no longer appears in `list` and no embeddings remain for that id.
7. Run `chronicle merge` on identity-enriched trace; verify accepted names render and unresolved speakers remain visibly uncertain.
8. Run `chronicle speakers assign --trace trace.jsonl --speaker-id S1 --name George --output corrected.trace.jsonl`; verify original file is unchanged and corrected output includes identity metadata.
9. Run a network-denied smoke after model files are installed; verify enroll/identify path still works locally.
