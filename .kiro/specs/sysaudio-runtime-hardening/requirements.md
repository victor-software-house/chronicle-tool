# Requirements Document

## Introduction

Chronicle `sysaudio` now captures real system audio through `/Applications/chronicle.app` with CoreAudio taps, follows the current default output device, and produces live transcripts without BlackHole or a Multi-Output Device. The next work hardens this verified path: remove misleading TCC failure language, debounce output-device rebuilds, and split diagnostics into operator-friendly channels and verbosity levels.

## Boundary Context

- **In scope**: `chronicle sysaudio` runtime messaging, CoreAudio default-output listener behavior, tap diagnostic logging, documentation/spec refresh for the verified local app flow.
- **Out of scope**: replacing CoreAudio taps with ScreenCaptureKit, adding screen recording, adding BlackHole routing as the default path, changing transcript/diarization semantics, broad launchd/login-item work.
- **Adjacent expectations**: existing PRD/ADR docs remain references; this Kiro spec is authoritative for the warning/debounce/logging cleanup.

## Requirements

### Requirement 1: Advisory System Audio TCC Preflight

**Objective:** As the chronicle operator, I want sysaudio startup messages to distinguish advisory preflight results from runtime capture health, so that a false private-SPI denial does not look like proof that capture is broken.

#### Acceptance Criteria

1. When private TCC preflight reports denied, the sysaudio command shall continue startup and log that the preflight is advisory/inconclusive, not a hard capture verdict.
2. When the CoreAudio tap starts and later observes nonzero PCM, the sysaudio command shall not continue implying that TCC denial is the active failure cause.
3. If runtime capture remains zero after the existing idle/no-buffer window, then the sysaudio command shall report runtime evidence and likely remediation separately from preflight status.
4. The System Audio Recording remediation text shall reference `/Applications/chronicle.app` as the preferred grant target for the local signed app flow.

### Requirement 2: Debounced Default Output Rebuild

**Objective:** As the chronicle operator, I want sysaudio to follow output-device switches without rebuilding for every transient CoreAudio notification, so that mid-capture routing changes are reliable and logs remain clear.

#### Acceptance Criteria

1. When macOS emits multiple default-output notifications during one switch, the tap source shall coalesce them and rebuild once after the output stabilizes.
2. When a notification is caused by Chronicle's own private aggregate-device churn and the resolved default output has not changed, the tap source shall ignore it.
3. When the stable default output differs from the active output, the tap source shall teardown and recreate tap, aggregate, IOProc, converter, and buffer warning state.
4. The tap source shall log one concise output-change message showing old and stable new output identifiers.
5. If rebuild fails, the tap source shall surface the error and finish streams rather than silently continuing in an invalid state.

### Requirement 3: Diagnostic Channels and Verbosity Levels

**Objective:** As the chronicle operator, I want logs separated by channel and verbosity level, so that normal live transcription is quiet while deep tap diagnostics remain available when debugging capture.

#### Acceptance Criteria

1. By default, sysaudio shall emit only operator-relevant lifecycle, output path, warning, and error messages.
2. With `--verbose`, sysaudio shall emit useful tap/channel summaries such as start, first callback, first converted buffer, first nonzero peak, and periodic summaries.
3. Per-buffer or every-64-buffer peak detail shall be gated behind a higher debug level or diagnostic channel, not ordinary `--verbose`.
4. Repeated latency warnings shall be rate-limited or summarized so a healthy live run does not flood stderr.
5. Log messages shall be consistently channel-prefixed so process monitors can watch specific channels without matching every tap buffer line.

### Requirement 4: Verification and Spec Synchronization

**Objective:** As a maintainer, I want code, docs, and specs to reflect the verified sysaudio path, so that future work starts from the actual contract instead of stale ScreenCaptureKit/CATap uncertainty.

#### Acceptance Criteria

1. After implementation, `swift test` shall pass.
2. After implementation, `scripts/make-app.sh --install` with `CHRONICLE_TEAM_ID=CXLYTY8DMR` shall produce a valid signed `/Applications/chronicle.app`.
3. A live `say` sysaudio smoke shall produce nonzero peak and transcript text in `finals.md` or `live.md`.
4. Documentation shall record that Chronicle sysaudio works without BlackHole/Multi-Output Device and follows the current default output.
5. `docs/STATUS.md` and relevant ADR text shall no longer imply that there is no working CoreAudio live-system-audio path on this machine.
