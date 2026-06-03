<!--
  Vendored from gotalab/cc-sdd v3.0.2 (https://github.com/gotalab/cc-sdd.git)
  Source path: tools/cc-sdd/templates/shared/settings/templates/specs/requirements-init.md | Materialized: 2026-05-26T19:52:37.629907+00:00
  Do not edit; bump dfetch.yaml and run vendor:materialize.
-->

# Requirements Document

## Introduction

Chronicle's ALAC audio sidecar writer (`AVAudioFileALACSink`) produces undecodable CAF files on macOS Tahoe because `AVAudioFile.close()` does not write the `pakt` (packet table) chunk required for ALAC VBR. Every recording session since the P11 ALAC production sink shipped has produced audio files with 0 reported duration, 0 packets, and no decodable audio — while transcription sidecars (finals, trace, live log) remain fully intact.

This was confirmed on 2026-06-03 when a weekly pod recording (mic 18 MB / 1046 s, sysaudio 6.5 MB / 396 s) produced broken CAFs. Recovery attempts failed because ALAC compressed frames have no inline length markers — heuristic frame boundary scanning misaligns after a few packets, causing cascading decode failures. Apple's AudioToolbox APIs (`AudioFileReadPacketData`, `ExtAudioFile`) also refuse to read the data without a valid pakt.

Multiple prior sessions are also affected: the Jun 2 overnight session (391 MB) and all 5 non-empty session directories produce identical "Missing packet table" failures. Additionally, 30 of 35 session directories created during May development are empty (failed recording starts), and the ChronicleApp Stop button was unresponsive during today's live capture (required `osascript -e 'quit app "ChronicleApp"'`).

This spec addresses the full audio recording reliability surface: fixing the sink, recovering existing broken recordings, cleaning up stale sessions, adding runtime integrity verification, and documenting the Tahoe framework bug.

## Boundary Context

- **In scope**: ALAC CAF sink replacement using a framework that properly manages pakt lifecycle; `chronicle repair-alac` subcommand for recovering existing broken CAFs; session directory garbage collection; write-time audio integrity checks; ADR-0002 amendment documenting the `AVAudioFile.close()` Tahoe bug; ChronicleApp Stop button reliability fix.
- **Out of scope**: changing the default audio format away from ALAC-in-CAF (ADR-0002 still governs that decision); replacing CoreAudio tap infrastructure (sysaudio-runtime-hardening owns that); daemon control plane changes (agent-safe-capture-daemon-control-plane owns that); transcript pipeline changes; new offline subcommands beyond repair-alac.
- **Adjacent expectations**: the `chronicle-menubar-app` spec's open verification tasks (8.2–8.5) cover end-to-end smoke and shutdown testing, which would also exercise the Stop button. The Stop button fix here addresses the root cause (main-thread blocking during capture finalization); the menubar spec's verification tasks confirm the user-visible behavior. The `sysaudio-runtime-hardening` spec is complete and its debounce/diagnostic behaviors are treated as the runtime baseline.

## Requirements

### Requirement 1: Reliable ALAC CAF Finalization

**Objective:** As the Chronicle operator, I want audio sidecar files to be fully decodable after capture stops, so that I have usable audio recordings alongside my transcripts.

#### Acceptance Criteria

1. When a capture session ends normally (operator stop, app quit, or CLI signal), the ALAC CAF audio sidecar shall contain a valid `pakt` chunk with correct per-packet byte sizes, total packet count, and total frame count.
2. When a capture session ends normally, the produced CAF shall be decodable by `afinfo` (reporting correct duration and packet count), `ffmpeg`/`ffprobe` (reporting correct duration), and `afconvert` (producing a byte-decodable PCM WAV).
3. If the audio sink encounters an unrecoverable write error mid-session, the sink shall log the error to stderr and preserve whatever audio data has been written up to that point in a recoverable state.
4. The ALAC CAF sink shall produce files that pass the existing P11 acceptance criteria: correct codec/container, comparable output size to the current AVAudioFile implementation, and successful readback.
5. The ALAC CAF sink shall support the same source formats as the current implementation: 16 kHz mono Int16 PCM (mic and sysaudio analyzer output).

### Requirement 2: Broken CAF Recovery Tool

**Objective:** As the Chronicle operator, I want to recover audio from existing broken ALAC CAF files that are missing the pakt chunk, so that prior recording sessions are not permanently lost.

#### Acceptance Criteria

1. Chronicle shall provide a `repair-alac` subcommand that accepts one or more broken ALAC CAF file paths and produces repaired copies with valid pakt chunks.
2. When given a broken CAF with intact ALAC-encoded audio bytes, the repair tool shall reconstruct per-packet byte sizes and write a valid pakt chunk that enables full decoding.
3. When the repair tool successfully repairs a file, `afinfo` shall report the correct duration and packet count, and `ffmpeg` shall decode the full file without errors.
4. When the repair tool encounters a file that is not a broken ALAC CAF (wrong format, truncated beyond recovery, or already valid), the tool shall report a clear diagnostic and skip the file without modifying it.
5. The repair tool shall write repaired files to a separate output path by default, preserving the original broken file as evidence.
6. When given the `--in-place` flag, the repair tool shall overwrite the original file with the repaired version.

### Requirement 3: Session Directory Hygiene

**Objective:** As the Chronicle operator, I want empty and failed session directories cleaned up, so that the session listing is not cluttered with artifacts from development and failed starts.

#### Acceptance Criteria

1. Chronicle shall provide a `gc` (garbage collect) subcommand that scans the chronicle output directory for empty or failed session directories.
2. A session directory shall be considered empty when it contains no audio files, no transcript files (finals.md, trace.jsonl, live.log), and no other sidecar artifacts.
3. When the operator runs `gc`, the tool shall list the empty directories found and their creation timestamps before removing anything.
4. When the operator confirms removal (or passes `--yes`), the tool shall delete the empty directories.
5. When a session directory contains any non-empty artifact (even partial audio or a single trace line), the tool shall not remove it.
6. The gc subcommand shall support `--dry-run` to preview what would be removed without deleting.

### Requirement 4: Write-Time Audio Integrity Verification

**Objective:** As the Chronicle operator, I want audio recording health verified during capture, so that broken audio files are detected while I can still act (restart, switch format) rather than discovered hours later.

#### Acceptance Criteria

1. While a capture session is recording audio, Chronicle shall periodically verify that the active audio sidecar contains valid, decodable ALAC data.
2. When write-time verification detects that the audio sidecar is not decodable (missing pakt, corrupt data, or zero-length packets), Chronicle shall log a warning to stderr with the session path and failure reason.
3. When write-time verification detects a failure and the ChronicleApp UI is active, the app shall display an audio health warning in the session info area.
4. Write-time verification shall not interfere with active recording — the check shall operate on a read-only snapshot or probe of the sidecar state, not interrupt the write pipeline.
5. Write-time verification shall run at most once per 60 seconds to avoid excessive IO during capture.

### Requirement 5: ChronicleApp Stop Button Reliability

**Objective:** As the Chronicle operator, I want the Stop button in the menu bar app to reliably stop capture within a bounded time, so that I do not need to resort to `osascript` or force-quit to end a recording.

#### Acceptance Criteria

1. When the operator clicks Stop in the ChronicleApp dropdown, the app shall initiate capture shutdown and update the UI to reflect stopping state within 500 ms.
2. When capture finalization (analyzer drain, sink flush) takes longer than the existing L3 timeout (5 s + 2 s), ChronicleApp shall force-terminate the capture pipeline and transition to idle state.
3. While capture is stopping, the Stop button shall be disabled and the dropdown shall show a stopping indicator, preventing duplicate stop requests.
4. If the capture pipeline is blocked or unresponsive, the Stop action shall not block the main thread — the UI shall remain interactive throughout shutdown.
5. When the operator uses `osascript -e 'quit app "ChronicleApp"'` or Cmd-Q during capture, the same bounded shutdown shall apply.

### Requirement 6: ADR-0002 Amendment — Tahoe AVAudioFile.close() Bug

**Objective:** As a Chronicle maintainer, I want the Tahoe `AVAudioFile.close()` bug documented in the project's decision record, so that future contributors understand why the sink was replaced and do not reintroduce `AVAudioFile` for ALAC VBR without verifying pakt behavior.

#### Acceptance Criteria

1. ADR-0002 shall include an amendment section documenting that `AVAudioFile.close()` on macOS 26 Tahoe does not write the CAF pakt chunk for ALAC VBR.
2. The amendment shall record the evidence trail: date of discovery, affected sessions, recovery attempts and their failures, and the replacement approach chosen.
3. The amendment shall note that `AVAudioFileALACSink` is retired in favor of the replacement sink, with the rationale for the choice.
4. The amendment shall be dated and follow the existing amendment format established in ADR-0002 (consistent with the 2026-05-13 and 2026-05-16 amendments).

### Requirement 7: Segment Rotation Compatibility

**Objective:** As the Chronicle operator, I want audio segment rotation (`--rotate-audio`) to continue working with the replacement ALAC sink, so that long sessions are split into bounded-size segments with individually valid CAF files.

#### Acceptance Criteria

1. When `--rotate-audio` is active, each rotated ALAC CAF segment shall be individually decodable with a valid pakt chunk.
2. When a rotation boundary is reached, the current segment shall be finalized (pakt written, file closed) before the next segment begins.
3. Segment rotation behavior (duration trigger, file naming, scratch/WAV/Opus alternate format support) shall remain unchanged from the current implementation.
