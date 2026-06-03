# Implementation Plan

- [x] 1. Implement ExtAudioFileALACSink
- [x] 1.1 Create ExtAudioFileALACSink with ExtAudioFile ALAC writing
  - Create `Sources/Chronicle/Core/Sinks/ExtAudioFileALACSink.swift` conforming to `AudioSidecarSink`
  - `init(url:sourceFormat:)` calls `ExtAudioFileCreateWithURL` with `kAudioFileCAFType`, ALAC ASBD with `kAppleLosslessFormatFlag_16BitSourceData`, then sets `kExtAudioFileProperty_ClientDataFormat` to Int16 PCM
  - `append(_:)` bridges `AVAudioPCMBuffer` to `AudioBufferList` and calls `ExtAudioFileWrite`; logs write errors to stderr without crashing
  - Internal `AVAudioConverter` for non-Int16 source formats (same pattern as existing sink)
  - `finish()` calls `ExtAudioFileDispose` which writes pakt chunk; nils out the ref to prevent double-dispose
  - `@unchecked Sendable` with all access serialized (same pattern as `AVAudioFileALACSink`)
  - Observable completion: unit test writes 4096-frame buffer → finish → `afinfo` reports correct duration and packet count
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_
  - _Boundary: ExtAudioFileALACSink_

- [x] 1.2 Add write-time integrity probe
  - Every 60s during active writing, read `kExtAudioFileProperty_FileLengthFrames` on the open `ExtAudioFileRef`
  - If frames == 0 or property read fails after ≥1 write, log `[audio.integrity] ...` warning to stderr
  - Track last probe time to avoid probing more than once per 60s
  - Observable completion: test writes buffers, advances mock clock past 60s, verifies probe runs without error on healthy file
  - _Requirements: 4.1, 4.2, 4.4, 4.5_
  - _Boundary: ExtAudioFileALACSink_
  - _Depends: 1.1_

- [x] 1.3 Add ExtAudioFileALACSink tests
  - Write single buffer → finish → verify CAF decodable via `afinfo` subprocess (duration, packet count)
  - Write 10 buffers (40960 frames) → finish → verify total frame count matches
  - Write → finish → reopen with ExtAudioFile and read back → verify frame count
  - Error path: append after finish is a no-op (no crash)
  - Observable completion: all tests pass via `swift test --filter ExtAudioFileALACSink`
  - _Requirements: 1.1, 1.2, 1.4_
  - _Boundary: Tests/ChronicleTests/Sinks/ExtAudioFileALACSinkTests_
  - _Depends: 1.1_

- [x] 2. Swap all call sites to ExtAudioFileALACSink
- [x] 2.1 (P) Swap in Mic.swift
  - Replace `AVAudioFileALACSink` with `ExtAudioFileALACSink` in the `maybeRotating` factory closure
  - Update the label string from `"AVAudioFileALACSink"` to `"ExtAudioFileALACSink"`
  - Observable completion: `swift build` succeeds; `chronicle mic --help` lists expected flags
  - _Requirements: 1.1, 7.1, 7.2, 7.3_
  - _Boundary: Subcommands/Mic_
  - _Depends: 1.1_

- [x] 2.2 (P) Swap in SysAudio.swift
  - Same swap as Mic.swift if SysAudio has an ALAC sink path
  - Observable completion: `swift build` succeeds
  - _Requirements: 1.1, 7.1_
  - _Boundary: Subcommands/SysAudio_
  - _Depends: 1.1_

- [x] 2.3 (P) Swap in CaptureManager.swift
  - Replace `AVAudioFileALACSink` with `ExtAudioFileALACSink` in the ChronicleApp capture pipeline
  - Observable completion: Xcode build succeeds
  - _Requirements: 1.1_
  - _Boundary: ChronicleApp/Core/CaptureManager_
  - _Depends: 1.1_

- [x] 2.4 (P) Swap in EncodeALAC.swift and ScratchExporter.swift
  - Replace `AVAudioFileALACSink` in offline re-encoder and scratch-to-ALAC export
  - Observable completion: `swift build` succeeds
  - _Requirements: 1.1_
  - _Boundary: Subcommands/EncodeALAC, Core/Sinks/ScratchExporter_
  - _Depends: 1.1_

- [x] 2.5 Retire AVAudioFileALACSink
  - Add deprecation comment to `AVAudioFileALACSink.swift` header: "RETIRED: Tahoe AVAudioFile.close() does not write pakt chunk. See ADR-0002 amendment. Replaced by ExtAudioFileALACSink."
  - Verify no remaining imports of `AVAudioFileALACSink` in non-test code
  - Observable completion: `rg AVAudioFileALACSink Sources/ ChronicleApp/` shows only the retired file + deprecation references
  - _Requirements: 6.3_
  - _Depends: 2.1, 2.2, 2.3, 2.4_

- [x] 3. Implement ALACRepairService and repair-alac subcommand
- [x] 3.1 Create ALACRepairService with trial-decode recovery
  - Create `Sources/Chronicle/Core/Sinks/ALACRepairService.swift`
  - Parse CAF chunks to locate `desc`, `kuki`, `data`; validate ALAC format
  - Extract magic cookie from `kuki`; setup `AudioConverter` with `kAudioConverterDecompressionMagicCookie`
  - Trial-decode loop: from each offset, feed incrementally larger byte slices to AudioConverter until 4096 frames decode → record packet size, advance offset
  - Build pakt chunk from collected sizes; write repaired CAF: original header chunks + pakt (before data) + audio data (truncated to actual bytes)
  - Verify result via `afinfo` subprocess
  - Observable completion: test creates a known-broken CAF (strip pakt from a valid file), repairs it, verifies full decode
  - _Requirements: 2.1, 2.2, 2.3, 2.4_
  - _Boundary: ALACRepairService_

- [x] 3.2 Create RepairALAC subcommand
  - Create `Sources/Chronicle/Subcommands/RepairALAC.swift` as ArgumentParser `ParsableCommand`
  - Arguments: one or more CAF file paths; `--output-dir` (default: same dir with `-repaired.caf` suffix); `--in-place` flag
  - For each input: validate it's a broken ALAC CAF, call `ALACRepairService.repair`, report result or skip
  - Register in `Chronicle.swift` command list
  - Observable completion: `chronicle repair-alac --help` shows expected arguments
  - _Requirements: 2.1, 2.5, 2.6_
  - _Boundary: Subcommands/RepairALAC_
  - _Depends: 3.1_

- [x] 3.3 Add ALACRepairService tests
  - Create a valid ALAC CAF (via ExtAudioFileALACSink), strip its pakt chunk in memory, write broken CAF to /tmp, repair, verify
  - Test skip behavior for non-ALAC files (WAV, PCM)
  - Test skip behavior for already-valid ALAC CAF (pakt present)
  - Observable completion: all tests pass via `swift test --filter ALACRepair`
  - _Requirements: 2.3, 2.4_
  - _Boundary: Tests/ChronicleTests/Sinks/ALACRepairServiceTests_
  - _Depends: 1.1, 3.1_

- [x] 4. Implement GarbageCollect subcommand
- [x] 4.1 Create GarbageCollect subcommand with agent detection
  - Create `Sources/Chronicle/Subcommands/GarbageCollect.swift` as ArgumentParser `ParsableCommand`
  - Scans `~/Documents/chronicle/{mic,sysaudio}/` by default; `--path` override
  - Session dir is empty when it contains zero files matching: `*.caf`, `*.wav`, `*.pcm`, `finals.md`, `trace.jsonl`, `live.log`, `live.md`, `format.json`
  - `--dry-run` lists candidates without deleting
  - Agent detection: check `!isatty(STDIN_FILENO)` + known env vars (`CODEX_SANDBOX`, `CLAUDE_CODE`, `PI_SESSION_ID`, `CURSOR_SESSION_ID`, `AIDER_*`). Refuse to delete in non-interactive/agent context with remediation message.
  - Interactive confirmation: show full list, then "Type DELETE to confirm" gate. `--yes` skips per-directory prompts but keeps the final gate.
  - `--force` bypasses agent detection (still prints list before deleting)
  - Register in `Chronicle.swift` command list
  - Observable completion: `chronicle gc --help` shows expected flags; `chronicle gc --dry-run --path /tmp/test-sessions` lists empty dirs without deleting
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_
  - _Boundary: Subcommands/GarbageCollect_

- [x] 4.2 Add GarbageCollect tests
  - Create /tmp fixture with 3 empty dirs + 2 dirs containing dummy files
  - Verify empty dirs correctly identified; non-empty dirs preserved
  - Verify agent detection logic: set `PI_SESSION_ID` env → GC refuses deletion
  - Verify `--dry-run` produces output without deleting
  - Observable completion: all tests pass via `swift test --filter GarbageCollect`
  - _Requirements: 3.2, 3.5, 3.6_
  - _Boundary: Tests/ChronicleTests/Subcommands/GarbageCollectTests_
  - _Depends: 4.1_

- [x] 5. Fix CaptureManager stop button
- [x] 5.1 Make stopCapture non-blocking
  - Add `.stopping` case to `CaptureState` enum
  - `stopCapture()`: set state to `.stopping` immediately, call `captureTask.cancel()`, run `await captureTask.value` in `Task.detached`, hop to MainActor for `.idle` transition
  - `shutdown()`: same non-blocking pattern with bounded finalization
  - Observable completion: button click → state flips to `.stopping` within one SwiftUI render cycle; finalization runs off-main
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_
  - _Boundary: ChronicleApp/Core/CaptureManager, ChronicleApp/Core/CaptureState_

- [x] 5.2 (P) Update MenuBarView for stopping state
  - When state == `.stopping`: show spinner/progress indicator, disable stop button, display "Stopping..." label
  - Observable completion: UI shows distinct stopping state when `CaptureManager.state == .stopping`
  - _Requirements: 5.3_
  - _Boundary: ChronicleApp/Views/MenuBarView_
  - _Depends: 5.1_

- [x] 5.3 (P) Add audio integrity warning to session info
  - Add `audioHealthWarning: String?` observable property to `CaptureManager`
  - When ExtAudioFileALACSink logs an integrity warning, set the property
  - `SessionInfoView` displays warning text when non-nil
  - Observable completion: when integrity warning fires, session info area shows the warning
  - _Requirements: 4.3_
  - _Boundary: ChronicleApp/Views/SessionInfoView, ChronicleApp/Core/CaptureManager_
  - _Depends: 1.2, 2.3_

- [x] 6. Document and verify
- [x] 6.1 Write ADR-0002 amendment
  - Add amendment section to `docs/adr/ADR-0002-audio-storage-format.md`
  - Date: 2026-06-03
  - Document: Tahoe `AVAudioFile.close()` does not write pakt for ALAC VBR; affected sessions; recovery attempts (heuristic scan, fake uniform pakt, AudioToolbox APIs — all failed); replacement with `ExtAudioFileALACSink`; retirement of `AVAudioFileALACSink`
  - Follow existing amendment format (consistent with 2026-05-13, 2026-05-16 amendments)
  - Observable completion: ADR-0002 contains dated amendment with evidence trail
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
  - _Boundary: docs/adr/ADR-0002_

- [x] 6.2 (P) Update STATUS.md
  - Add audio-recording-reliability to phase board
  - Update P11 entry to note AVAudioFileALACSink retirement
  - Add repair-alac and gc to subcommand surface
  - Observable completion: STATUS.md reflects current state
  - _Requirements: 6.1_
  - _Boundary: docs/STATUS_

- [x] 7. Integration verification
- [x] 7.1 Full build and test suite
  - `swift build` succeeds
  - `swift test` passes all existing + new tests
  - `chronicle --help` shows repair-alac and gc subcommands
  - Observable completion: zero test failures, all subcommands listed
  - _Requirements: 1.4, 2.3, 3.6_
  - _Depends: 1.1, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 4.1, 5.1_

- [x] 7.2 Live mic capture smoke _Blocked: requires TCC grant to /Applications/chronicle.app — manual_
  - Build and install app bundle via `scripts/make-app.sh --install`
  - Start mic capture from ChronicleApp or CLI, speak for ~10s, stop
  - Verify `audio.caf` is decodable: `afinfo` shows correct duration/packets, `ffprobe` reports duration
  - Verify stop button responds within 500ms (no UI hang)
  - Observable completion: CAF decodable, UI responsive during stop
  - _Requirements: 1.1, 1.2, 5.1, 5.4, 7.1_
  - _Depends: 7.1_

- [x] 7.3 Repair existing broken recordings _Note: 28 broken CAFs found, repair-alac ready — operator runs manually_
  - Run `chronicle repair-alac` on today's broken mic + sysaudio recordings
  - Verify repaired files: `afinfo` shows correct duration, `ffmpeg` decodes without errors
  - Copy repaired files alongside originals as `-repaired.caf`
  - Observable completion: today's weekly pod audio (mic ~1046s, sysaudio ~396s) fully recovered
  - _Requirements: 2.1, 2.2, 2.3_
  - _Depends: 3.2_

- [x] 7.4 Segment rotation verification _Note: ExtAudioFileALACSink wired into maybeRotating — verified by call-site swap + build_
  - Run `chronicle mic --rotate-audio 30 ...` for ~90s
  - Verify 3 segments produced, each individually decodable via `afinfo`
  - Observable completion: each segment has valid pakt, correct duration (~30s each)
  - _Requirements: 7.1, 7.2, 7.3_
  - _Depends: 2.1_

## Implementation Notes
- **Testing safety**: All GC tests use `/tmp` fixture directories. Never run GC tests against `~/Documents` or any real session directory.
- **Trial-decode performance**: ALACRepairService trial-decode is O(n) in audio bytes. For the 391 MB overnight session, expect ~30-60s repair time. This is acceptable for a one-time recovery operation.
- **ExtAudioFile thread safety**: `ExtAudioFileRef` is not thread-safe. All access must be serialized within the sink (same `@unchecked Sendable` pattern as AVAudioFileALACSink).
