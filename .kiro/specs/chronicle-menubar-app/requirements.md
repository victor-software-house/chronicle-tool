<!--
  Vendored from gotalab/cc-sdd v3.0.2 (https://github.com/gotalab/cc-sdd.git)
  Source path: tools/cc-sdd/templates/shared/settings/templates/specs/requirements-init.md | Materialized: 2026-05-26T19:52:37.629907+00:00
  Do not edit; bump dfetch.yaml and run vendor:materialize.
-->

# Requirements Document

## Project Description (Input)
Chronicle is a local-first macOS audio capture, transcription, and diarization toolkit currently operating as a CLI-only tool. The operator must type long terminal commands to start live capture sessions and has no persistent UI presence, no quick toggle for recording, and no way to see live transcript output without tailing files. The `make-app.sh` shell script wrapping `swift build` + `codesign` + `cp` is a brittle workaround for TCC identity.

This spec delivers a macOS menu bar app (`MenuBarExtra`) that gives the operator two-click control over live mic and system audio capture with streaming diarization. The app extracts `Core/` as a shared `ChronicleCore` SwiftPM library, creates a proper Xcode app project with native signing and entitlements, and retires `make-app.sh`. It is designed from day one as the future daemon host process for the P12 control plane, following the Docker Desktop / Tailscale pattern where the menu bar app IS the always-running service.

## Requirements
<!-- Will be generated in /kiro-spec-requirements phase -->
