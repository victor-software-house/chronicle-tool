# Implementation Plan

- [x] 1. Update advisory TCC preflight messaging
  - Change sysaudio startup copy so private TCC preflight denial is advisory/inconclusive.
  - Point remediation at `/Applications/chronicle.app` for the signed local app path.
  - Update tests expecting old hard-denial wording.
  - _Requirements: 1.1, 1.2, 1.3, 1.4_
  - _Boundary: SysAudio CLI, TCCPreflight_

- [x] 2. Debounce default-output tap rebuilds
  - Add a listener debounce generation/cancel mechanism in `CoreAudioTapSource`.
  - Re-read the default output after the debounce delay and rebuild only if the stable ID differs from the active output.
  - Keep the current full tap/aggregate/IOProc teardown and recreate sequence.
  - Emit one concise stable-output-change log line.
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5_
  - _Boundary: CoreAudioTapSource_

- [x] 3. Separate sysaudio diagnostics by channel and verbosity
  - Keep default output to lifecycle, sidecar paths, warnings, and errors.
  - Make `--verbose` emit first callback, first converted buffer, first nonzero peak, start/rebuild, and periodic summaries only.
  - Move repeated per-buffer/64-buffer peak detail behind a debug channel or higher verbosity flag.
  - Rate-limit or summarize repeated latency warning output.
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_
  - _Boundary: CoreAudioTapSource, SysAudio CLI, TranscriptionLatencyMonitor_

- [x] 4. Refresh docs/specs for verified sysaudio path
  - Update `docs/STATUS.md` and ADR-0007 so they no longer imply there is no working CoreAudio live-system-audio path on this machine.
  - Document that Chronicle sysaudio works without BlackHole/Multi-Output Device and follows the current default output.
  - Keep legacy PRD/ADR docs as references; this Kiro spec governs the current cleanup.
  - _Requirements: 4.4, 4.5_
  - _Boundary: docs, .kiro/specs/sysaudio-runtime-hardening_

- [x] 5. Verify signed app and live sysaudio proof
  - Run `swift test`.
  - Run `CHRONICLE_TEAM_ID=CXLYTY8DMR scripts/make-app.sh --install`.
  - Start `/Applications/chronicle.app/Contents/MacOS/chronicle sysaudio` and overlap a `say` process.
  - Confirm nonzero peak and transcript text in sidecars.
  - Commit and push all changes.
  - _Requirements: 4.1, 4.2, 4.3_
  - _Depends: 1, 2, 3, 4_
