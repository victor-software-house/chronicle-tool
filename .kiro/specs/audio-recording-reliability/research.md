# Research Notes — audio-recording-reliability

## 1. Root Cause: AVAudioFile.close() on Tahoe

**Confirmed bug**: `AVAudioFile.close()` on macOS 26 Tahoe does not write the CAF `pakt` (packet table) chunk for ALAC VBR. The code comment claims "AVAudioFile finalizes container metadata on close/deinit" — this is false on Tahoe for ALAC.

**External corroboration**: GitHub issue `karansinghgit/speaktype#32` (2026-02-22) reports transcription fails on "macOS 26 (Tahoe)" with AVAudioFile/FigAssetWriter errors, with a PR (#41) fixing "recorder finalization handling." A related `idanyekutiel/wispah` commit (2026) is titled "ultimate recording reliability" fixing finalization. The pattern is consistent: AVAudioFile on Tahoe has finalization regressions for compressed formats.

**CAF spec requirement**: per Apple's CAF spec, CAF files with variable bit rate audio (ALAC) *must* include exactly one Packet Table chunk, and the packet table *must always reflect the current state* of the audio data.

## 2. ExtAudioFile as the Replacement (Req 1)

ExtAudioFile is the proven path for writing ALAC-in-CAF:

- `ExtAudioFileCreateWithURL(url, kAudioFileCAFType, &alacASBD, nil, eraseFlag, &outFile)` — creates the file with ALAC destination format.
- `ExtAudioFileSetProperty(outFile, kExtAudioFileProperty_ClientDataFormat, pcmASBD)` — sets the client-side PCM format. ExtAudioFile handles codec magic cookie and internal converter setup.
- `ExtAudioFileWrite(outFile, frameCount, &bufList)` in a loop — writes PCM; ExtAudioFile encodes to ALAC and builds the packet table.
- `ExtAudioFileDispose(outFile)` — finalizes the file, writing the pakt chunk, magic cookie, and data chunk size.

**Key gotcha for ALAC**: set `kAppleLosslessFormatFlag_16BitSourceData` in the destination ASBD's `mFormatFlags` (value `4`). Without this, ExtAudioFile may produce larger-than-expected files or misinterpret bit depth.

**Key gotcha for streaming**: ExtAudioFile writes the pakt chunk on dispose. If the process crashes before dispose, the pakt is lost — same as AVAudioFile. The defense is segment rotation (`--rotate-audio`) to bound the crash window. For additional safety, the design should consider periodic `ExtAudioFileDispose` + reopen (rotate) at configurable intervals.

## 3. Recovery: ALAC Frame Parsing (Req 2)

**Why heuristic scanning fails**: ALAC compressed frames have no fixed magic bytes or inline length markers. The byte `& 0xF0 == 0x00` heuristic catches some frame starts but misaligns on content bytes that coincidentally match the pattern. Once misaligned, every subsequent packet is garbage.

**How ALAC framing actually works** (per `macosforge/alac` reference decoder):
- Each frame starts with a tag (3 bits), headerByte (8 bits).
- headerByte bits: partial-frame flag (if set, 32-bit frame length follows), escape flag (uncompressed mode), shift-off bits (extra uncompressed bytes).
- Compressed frames use an Adaptive Golomb (AG) compressor for entropy-coded data — no fixed-length markers.
- The only reliable way to find frame boundaries is to parse the ALAC bitstream using the magic cookie's codec config (frameLength, etc.).

**Recovery approach**: use Apple's own `AudioConverter` with `kAudioConverterDecompressionMagicCookie` set from the CAF's `kuki` chunk. Feed candidate packet slices (starting from offset 0, incrementing) until the converter successfully decodes 4096 frames → that gives the exact packet size. Repeat from the next offset. This is O(n) in audio bytes but guaranteed correct because Apple's decoder validates each frame.

**Alternative**: port the ALAC reference decoder's frame parser in Swift. The C++ source at `macosforge/alac/codec/ALACDecoder.cpp` is ~600 lines; the frame-header parsing is the first ~80 lines of `Decode()`. This would be faster than trial-decode but requires maintaining a parser.

**Recommendation**: trial-decode via AudioConverter is safer and leverages Apple's decoder. Performance is acceptable for repair (a one-time operation, not hot path).

## 4. Stop Button Reliability (Req 5)

**Root cause hypothesis**: `CaptureManager.stopCapture()` is an async function that awaits `captureTask?.value`. If the capture task's finalization path (analyzer drain, sink flush) blocks or takes too long, the await blocks the caller. If the caller is on the main actor (SwiftUI button action), the UI freezes.

**Research findings**:
- Apple's "Understanding Hangs" guidance: main-thread work must stay under 250 ms; anything longer is a "hang."
- Swift Observation framework issue `swiftlang/swift#84954`: property changes missed when observation handler is blocked.
- Task cancellation with MainActor isolation can cause executor hopping issues (`swiftlang/swift#88259`).

**Fix pattern**:
1. Stop button handler should only flip UI state (`.stopping`) and call `task.cancel()` — both instant.
2. Actual finalization (await captureTask.value) should run in a detached task, not on the main actor.
3. When the detached finalization completes, it hops back to main actor to set state to `.idle`.
4. If finalization exceeds the L3 timeout (already implemented: 5s + 2s), force-kill the pipeline.

**macOS 26 MenuBarExtra caveat**: macOS 26 introduced a menu bar permission toggle that can hide status items. Not directly related to stop-button responsiveness, but worth noting for app visibility issues.

## 5. Session GC (Req 3)

Straightforward directory scan. Key safety constraints from operator:
- **Never run GC on the real Documents directory during testing** — always copy dummy files to /tmp dirs for tests.
- GC must list before deleting, support --dry-run, and never touch dirs with any content.

## 6. Write-Time Verification (Req 4)

With ExtAudioFile as the writer, verification can be simple: every 60s, read the current packet count via `kExtAudioFileProperty_FileLengthFrames`. If it returns 0 or errors, the file is broken. This is cheaper than reopening and decoding — it's a property read on the already-open file handle.

## 7. Segment Rotation Compatibility (Req 7)

ExtAudioFile naturally supports rotation: dispose current file → create new file. Each segment gets its own pakt on dispose. The existing `AudioSidecarCombinators.swift` rotation logic just needs to call the replacement sink's finish/init cycle.
