<!--
  Vendored from gotalab/cc-sdd v3.0.2 (https://github.com/gotalab/cc-sdd.git)
  Source path: tools/cc-sdd/templates/shared/settings/templates/specs/requirements-init.md | Materialized: 2026-05-26T19:52:37.629907+00:00
  Do not edit; bump dfetch.yaml and run vendor:materialize.
-->

# Requirements Document

## Introduction

Chronicle is a local-first macOS audio capture, transcription, and diarization toolkit currently operated exclusively through the CLI. Starting a live capture session requires typing long terminal commands and monitoring output by tailing log files. There is no persistent UI presence, no quick toggle for recording, and the `make-app.sh` shell script that assembles the `.app` bundle is a fragile workaround for TCC identity.

This spec delivers a macOS menu bar application that provides persistent, two-click access to live capture controls, real-time transcript visibility, and session management. The menu bar app replaces the CLI as the primary operator interface for live mic and system audio recording, while the CLI continues to serve offline subcommands. The app is designed as the future host process for the daemon control plane (P12).

## Boundary Context

- **In scope**: Menu bar status icon with dropdown; start/stop controls for mic, sysaudio, or both; diarization toggle; live transcript preview with speaker labels; session duration and source info; open session folder in Finder; launch-at-login; clean shutdown with capture finalization; properly signed app bundle replacing `make-app.sh`; CLI continuity for offline subcommands.
- **Out of scope**: Daemon RPC server and Unix socket (deferred to P12 spec update); CLI-to-app RPC client wiring; floating transcript overlay window; UI for offline subcommands (transcribe, diarize, merge, etc.); App Store distribution or notarization; manual audio output device selection (sysaudio follows default output automatically); locale or language selection UI; live tagging UI.
- **Adjacent expectations**: The app consumes the existing Core/ capture, transcription, and diarization protocols without modifying their behavior. The CLI executable continues to build and run independently for offline subcommands. The daemon control plane spec (P12) will later extend this app process with RPC capabilities; this spec does not block or modify P12.

## Requirements

### Requirement 1: Menu Bar Presence

**Objective:** As the operator, I want Chronicle to appear as a persistent icon in the macOS menu bar, so that I can access capture controls without switching to a terminal.

#### Acceptance Criteria

1. When ChronicleApp is running, ChronicleApp shall display a status icon in the macOS menu bar.
2. When the operator clicks the menu bar icon, ChronicleApp shall display a dropdown with capture controls and session information.
3. While no capture session is active, ChronicleApp shall display the status icon in an idle visual state.
4. While a capture session is recording, ChronicleApp shall display the status icon in a recording visual state distinct from idle.
5. If a capture error occurs (source failure, TCC denial, or finalization timeout), ChronicleApp shall display the status icon in an error visual state distinct from idle and recording.

### Requirement 2: Capture Source Controls

**Objective:** As the operator, I want to start and stop mic and system audio capture from the dropdown, so that I can control recording without typing CLI commands.

#### Acceptance Criteria

1. The dropdown shall provide controls to start capture for microphone, system audio, or both sources simultaneously.
2. When the operator activates a capture source, ChronicleApp shall begin recording and transcribing audio from that source and create the session output directory.
3. When the operator deactivates a capture source, ChronicleApp shall stop recording from that source and finalize any pending transcription.
4. While a capture session is active, the dropdown shall indicate which sources are currently recording.
5. When both mic and sysaudio sources are active, the operator shall be able to stop each source independently.
6. While a capture session is active, sysaudio shall capture from the current default audio output device without requiring manual device selection.

### Requirement 3: Diarization Control

**Objective:** As the operator, I want to toggle speaker diarization on or off from the dropdown, so that I can control whether speaker labels appear in transcripts.

#### Acceptance Criteria

1. The dropdown shall provide a toggle for streaming speaker diarization.
2. When diarization is enabled and a capture session is active, ChronicleApp shall identify and label speakers in the transcript output.
3. When diarization is disabled and a capture session is active, ChronicleApp shall produce transcripts without speaker labels.
4. The diarization toggle state shall persist across app launches.
5. When diarization is toggled while no capture session is active, ChronicleApp shall apply the new setting to the next capture session started.

### Requirement 4: Live Transcript Preview

**Objective:** As the operator, I want to see recent transcript lines in the dropdown, so that I can verify capture is working and glance at content without opening files.

#### Acceptance Criteria

1. While a capture session is active, the dropdown shall display the most recent transcript lines from the active source(s).
2. When new transcript text arrives during a capture session, the preview shall update to show the latest content.
3. Where diarization is enabled, the transcript preview shall include speaker labels alongside each transcript line.
4. While no capture session is active, the transcript preview area shall indicate that no session is running.

### Requirement 5: Session Information

**Objective:** As the operator, I want to see current session details in the dropdown, so that I know how long I've been recording and what sources are active.

#### Acceptance Criteria

1. While a capture session is active, the dropdown shall display the elapsed recording duration.
2. While a capture session is active, the dropdown shall display which audio sources are currently recording.
3. Where diarization is enabled and speakers have been identified, the dropdown shall display the number of distinct speakers detected.

### Requirement 6: Session File Access

**Objective:** As the operator, I want to quickly open the current session's output folder, so that I can review transcripts, audio, and trace files.

#### Acceptance Criteria

1. While a capture session is active or the most recent session's output exists, the dropdown shall provide an action to open the session output folder.
2. When the operator selects the open-folder action, ChronicleApp shall reveal the session's output directory in Finder.

### Requirement 7: Launch at Login

**Objective:** As the operator, I want ChronicleApp to optionally start when I log in, so that it's always available in the menu bar without manual launch.

#### Acceptance Criteria

1. The dropdown shall provide a toggle to enable or disable launch at login.
2. When launch-at-login is enabled, ChronicleApp shall start automatically after the operator logs into macOS.
3. When launch-at-login is disabled, ChronicleApp shall not start automatically after login.
4. The launch-at-login preference shall persist across app quits and system restarts.

### Requirement 8: Clean Shutdown

**Objective:** As the operator, I want quitting ChronicleApp to cleanly finalize any active capture, so that I don't lose transcript or audio data.

#### Acceptance Criteria

1. The dropdown shall provide a quit action.
2. When the operator selects quit while a capture session is active, ChronicleApp shall finalize all pending transcription and flush all sidecar files (trace, finals, audio) before terminating.
3. If finalization exceeds a bounded timeout, ChronicleApp shall force-terminate capture and preserve whatever data has already been written to disk.

### Requirement 9: Single Instance Enforcement

**Objective:** As the operator, I want only one instance of ChronicleApp running at a time, so that capture sources are not contested by duplicate processes.

#### Acceptance Criteria

1. If ChronicleApp is already running when a second launch is attempted, the second instance shall activate the existing instance's menu bar presence and terminate itself.

### Requirement 10: CLI Continuity

**Objective:** As the operator, I want the existing `chronicle` CLI to continue working for offline subcommands, so that my existing workflows are not disrupted by the new app.

#### Acceptance Criteria

1. The CLI executable shall continue to support all existing subcommands (transcribe, diarize, merge, describe, classify, tag, summarize, translate, ocr, encode-opus, encode-alac, scratch-export) without behavioral changes.
2. The CLI's existing test suite shall continue to pass without modification to test code.

### Requirement 11: App Build and Signing

**Objective:** As the operator, I want the menu bar app to be a properly signed macOS application with stable TCC grants, so that Microphone and System Audio Recording permissions survive rebuilds.

#### Acceptance Criteria

1. ChronicleApp shall be buildable as a signed macOS application with a stable bundle identifier (`com.victor-software-house.chronicle`).
2. When ChronicleApp is rebuilt and reinstalled, existing TCC grants for Microphone and System Audio Recording shall remain valid.
3. The operator shall be able to build and install ChronicleApp without the `make-app.sh` shell script.
4. The operator shall be able to grant TCC permissions to ChronicleApp through System Settings using the standard macOS flow.
