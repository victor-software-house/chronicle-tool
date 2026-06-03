<!--
  Vendored from gotalab/cc-sdd v3.0.2 (https://github.com/gotalab/cc-sdd.git)
  Source path: tools/cc-sdd/templates/shared/settings/templates/specs/requirements-init.md | Materialized: 2026-05-26T19:52:37.629907+00:00
  Do not edit; bump dfetch.yaml and run vendor:materialize.
-->

# Requirements Document

## Project Description (Input)

`AVAudioFile.close()` on macOS Tahoe does not write the CAF `pakt` (packet table) chunk for ALAC VBR, leaving every audio file produced by `AVAudioFileALACSink` undecodable — 0 duration, 0 packets, rejected by ffmpeg/afconvert/AudioToolbox. This was discovered on 2026-06-03 when today's weekly pod recording (mic 18 MB + sysaudio 6.5 MB, ~17 min) produced broken CAFs despite transcriptions being fully intact (66 mic finals, 83 sysaudio finals, ~1500 trace entries). Heuristic ALAC frame boundary scanning fails because compressed ALAC frames have no inline length markers; misalignment after a few packets causes cascading decode failures across hundreds of packets. Multiple prior sessions are also affected (Jun 2 overnight session, 391 MB). Additionally, 30 of 35 session directories are empty from failed starts during May development iterations, and the ChronicleApp Stop button was unresponsive during live capture (required `osascript -e 'quit app "ChronicleApp"'` to stop). This spec covers: (1) replacing AVAudioFileALACSink with ExtAudioFile API that properly manages the pakt chunk lifecycle, (2) a `chronicle repair-alac` subcommand using AudioConverter trial-decode or ALAC reference decoder frame parsing to recover existing broken CAFs, (3) session directory garbage collection for empty/failed starts, (4) write-time audio integrity verification so broken audio is caught during recording rather than after, and (5) documenting the Tahoe `AVAudioFile.close()` bug as an ADR-0002 amendment with the evidence trail.

## Requirements
<!-- Will be generated in /kiro-spec-requirements phase -->
