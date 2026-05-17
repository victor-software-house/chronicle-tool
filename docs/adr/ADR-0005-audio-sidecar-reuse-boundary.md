---
title: "Audio sidecar reuse boundary"
adr: ADR-0005
status: Accepted
date: 2026-05-17
prd: "PRD-001-resilient-multi-source-daemon"
decision: "Use Apple-native codec/container APIs directly and keep Chronicle-owned rotation, fan-out, raw-PCM scratch, and repair/export policy instead of adopting a third-party audio framework or runtime media process"
---

# ADR-0005: Audio sidecar reuse boundary

## Status

Accepted

## Date

2026-05-17

## Requirement Source

* **PRD**: [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](../prd/PRD-001-resilient-multi-source-daemon.md)
* **Decision Point**: FR-1 segmented audio capture, FR-8 repair/recovery, and the P11 ALAC production sidecar delivered by ADR-0002's 2026-05-16 amendment.
* **Related ADRs**: [ADR-0001](ADR-0001-modular-pipeline-architecture.md) defines the protocol-oriented sink boundary; [ADR-0002](ADR-0002-audio-storage-format.md) selects ALAC-in-CAF + raw scratch as the default storage model.

## Context

Chronicle now writes live audio through `AudioSidecarSink` implementations under `Sources/Chronicle/Core/Sinks/`:

| File                            | Role                                                                                          | Approx. size | Commodity vs Chronicle-specific                |
| ------------------------------- | --------------------------------------------------------------------------------------------- | -----------: | ---------------------------------------------- |
| `AudioSidecarSink.swift`        | small async append/finish protocol                                                            |       27 LOC | Chronicle-specific boundary from ADR-0001      |
| `AVAudioFileALACSink.swift`     | ALAC-in-CAF writer through `AVAudioFile` + Int16 conversion                                   |      138 LOC | mostly Apple-owned codec/container work        |
| `AudioSidecarCombinators.swift` | `CompositeAudioSidecarSink` fan-out + `RotatingAudioSidecarSink` duration-based file rotation |      102 LOC | Chronicle-specific orchestration               |
| `RollingPCMScratchSink.swift`   | headerless raw-PCM ring, TTL prune, `format.json` manifest                                    |      232 LOC | Chronicle-specific recovery tier               |
| `WAVSidecarSink.swift`          | WAV writer through `AVAudioFile`                                                              |       37 LOC | mostly Apple-owned                             |
| `OpusCAFSink.swift`             | opt-in Opus-in-CAF writer through `AVAudioConverter` + AudioToolbox packet writes             |      249 LOC | rare lower-level Apple glue; no longer default |

The default path is not a ground-up codec or muxer implementation. `AVAudioFile` owns ALAC encoding, CAF container writing, packet tables, magic-cookie handling, finalization, and readback compatibility. Chronicle owns policy around that writer: when to rotate, how to name segments, how to fan out each buffer to durable ALAC plus scratch, how to bound scratch retention, and how to leave enough metadata for recovery.

This distinction matters because the custom code being small does not automatically prove it is robust enough. A reusable library would only be better if it reduced risk in Chronicle's actual constraints:

* 24/7 macOS daemon operation.
* No Homebrew/runtime media-process dependency for normal capture.
* Stable TCC identity: capture stays in the Chronicle process.
* STT parity against the 6870 s reference WAV.
* ALAC-in-CAF default already verified by ADR-0002.
* Parallel raw PCM scratch for crash recovery and premium-STT bursts.
* Audio-duration rotation rather than wall-clock-only file chopping.
* Simple artifacts operators can inspect with `AVAudioFile`, `ffprobe`, or manual scratch export.

On 2026-05-17, Apple APIs, Swift libraries, and media-pipeline alternatives were audited to determine whether Chronicle should replace its custom sink/rotation/scratch code with a more complete implementation.

## Decision Drivers

* **Preserve verified STT behavior.** The ALAC-in-CAF default passed the long-reference byte-compare/WER gate in ADR-0002; changing containers or codecs reopens that evidence.
* **Keep capture in process.** A subprocess encoder adds pipe backpressure, process supervision, opaque failure states, and a second binary identity around macOS TCC.
* **Avoid runtime dependency sprawl.** Chronicle is a single Swift executable using Apple frameworks plus explicitly chosen ML dependencies. ffmpeg/GStreamer as daemon-time dependencies are too large for the storage sidecar alone.
* **Own Chronicle-specific recovery semantics.** No surveyed library ships the exact combination of rotated durable sidecar + bounded raw-PCM ring + manifest + future repair/export hooks.
* **Do not hide risk behind a dependency.** A framework is only useful if it proves better crash, continuity, and efficiency properties than the current code. Most candidates wrap the same Apple APIs or target a different artifact model.
* **Keep future migration path explicit.** If the requirement changes to "active segment must remain playable after hard crash without scratch," the right answer is probably a container change to fragmented MP4/CMAF, not a small library swap.

## Considered Options

### Option 1: Keep current Apple-native sinks plus Chronicle-owned rotation and scratch

Use `AVAudioFileALACSink` for ALAC-in-CAF, `RotatingAudioSidecarSink` for numbered segments, `CompositeAudioSidecarSink` for ALAC + scratch fan-out, and `RollingPCMScratchSink` for headerless raw PCM recovery.

* Good, because Apple still owns the hard codec/container work (`AVAudioFile` reads and writes `AVAudioPCMBuffer` objects and exposes explicit `close()` for write-finalization control).
* Good, because the ALAC-in-CAF output already passed the project-specific long-reference verification in ADR-0002.
* Good, because runtime dependency count stays unchanged.
* Good, because every recovery policy is local and testable: segment naming, buffer-boundary rotation, scratch TTL, and `format.json` interpretation.
* Good, because raw scratch has no finalization step; bytes that reach disk remain usable even if the active CAF's final metadata is lost.
* Bad, because Chronicle owns the correctness of rotation continuity, scratch serialization, TTL pruning, and future scratch export.
* Bad, because the active ALAC CAF segment is still not guaranteed readable after hard kill; scratch mitigates actual audio loss, but operators may need repair/export tooling.
* Bad, because `CompositeAudioSidecarSink` currently writes child sinks sequentially. If one sink blocks, later sinks wait. This is acceptable at current 16 kHz mono rates but should be measured if source bandwidth grows.
* Bad, because `RollingPCMScratchSink` allocates a `Data` buffer per append while interleaving samples. This is acceptable for current analyzer PCM but should be profiled before multi-channel/high-rate expansion.

### Option 2: Use higher-level Apple recording APIs (`AVAudioRecorder`, `SCRecordingOutput`)

Replace sidecar writers with high-level recorders.

* Good, because these APIs are Apple-supported and reduce explicit file-write code.
* Bad, because `AVAudioRecorder` records to one URL with record/pause/stop semantics; it does not provide rotated segments or a raw scratch ring.
* Bad, because `SCRecordingOutput` is ScreenCaptureKit-oriented, writes one output URL, and does not provide Chronicle's ALAC-in-CAF sidecar shape or separate scratch tier.
* Bad, because neither API exposes the per-buffer fan-out Chronicle needs for simultaneous STT analyzer input, durable sidecar, and scratch recovery.

### Option 3: Use `AVAssetWriter` segmentation / HLS / CMAF

Switch the durable sidecar from ALAC-in-CAF files to Apple `AVAssetWriter` segmented output, using `preferredOutputSegmentInterval`, `AVAssetWriterDelegate`, and HLS/CMAF profiles.

* Good, because Apple has native segment-oriented writer APIs for fMP4/HLS/CMAF workflows.
* Good, because fragmented MP4/CMAF is a better fit if the future hard requirement is an active fragment that remains playable after interruption.
* Bad, because the segmentation path is not ALAC-in-CAF. It changes the artifact model to init segments/fragments/playlists or fMP4-like outputs.
* Bad, because Chronicle would still need scratch-ring policy, disk writing of segment data, manifest management, and STT parity re-validation.
* Bad, because this would amend ADR-0002's accepted storage contract and reopen the codec/container decision.
* Bad, because known community samples document AVAssetWriter segmented-output leaks/crashes in some audio/video cases; it is not a risk-free replacement.

### Option 4: Use third-party Swift audio frameworks

Surveyed candidates included AudioKit, SFBAudioEngine, swift-capture-kit, AudioConvertionKit, TheAmazingAudioEngine, SwiftAudio/AudioStreamer-style playback packages, and small Opus/CAF converters.

* Good, because mature projects like AudioKit and SFBAudioEngine have broader audio ecosystems and test coverage in their domains.
* Good, because swift-capture-kit is the closest architectural match found: Swift 6.2, ALAC-related types, `FileOutput`, and file rotation configuration.
* Bad, because AudioKit targets synthesis/DSP/engine graphs; recorder code still ultimately relies on Apple file writers and does not provide segmented ALAC CAF + raw scratch.
* Bad, because SFBAudioEngine is strongest for playback, metadata, decoding, and offline conversion; it is not a live `AVAudioPCMBuffer` sidecar sink with a Chronicle recovery ring.
* Bad, because swift-capture-kit is very new, low-adoption, and uses an entire capture-session/output abstraction. It has file rotation but not Chronicle's scratch model or verified ALAC-in-CAF parity path.
* Bad, because AudioConvertionKit and small Opus/CAF converters are offline conversion tools or immature single-purpose wrappers, not daemon-time capture sinks.
* Bad, because adopting any of these would still leave Chronicle owning the most important pieces: raw scratch, recovery manifest, segment continuity tests, and PRD-specific acceptance gates.

### Option 5: Use ffmpeg as a daemon-time encoder/segmenter

Pipe PCM from Chronicle to an ffmpeg process and use ffmpeg's segment muxer with ALAC/CAF output.

* Good, because ffmpeg can encode ALAC and segment outputs; `ffmpeg-formats` documents the segment/stream\_segment/ssegment muxers.
* Good, because ffmpeg remains useful as an export, verification, and manual repair tool.
* Bad, because daemon-time ffmpeg adds a subprocess, pipe backpressure, stderr/error parsing, lifecycle supervision, and resynchronization after encoder failure.
* Bad, because the active CAF segment still needs finalization; kill probes and media-pipeline analysis show ffmpeg does not solve the ALAC/CAF tail problem.
* Bad, because raw scratch remains necessary, so ffmpeg would not replace the recovery tier.
* Bad, because direct ffmpeg capture would create a separate TCC identity; piped ffmpeg encode avoids TCC but keeps process and pipe risk.
* Bad, because Homebrew ffmpeg is a large runtime dependency and bundling/signing it would be disproportionate.

### Option 6: Use GStreamer `splitmuxsink` / robust `qtmux`

Adopt GStreamer for a full media pipeline, especially `splitmuxsink` and robust MP4 muxing.

* Good, because `splitmuxsink` is a mature segmentation primitive with async finalization.
* Good, because GStreamer's `qtmux` robust muxing can reserve/rewrite MP4 headers so interrupted recordings remain playable.
* Bad, because robust muxing is for MP4/qtmux-style outputs, not ALAC-in-CAF. GStreamer's CAF path is via libav wrappers and does not remove CAF finalization risk.
* Bad, because this is a container migration, not a drop-in replacement for current sidecars.
* Bad, because GStreamer brings a large runtime dependency graph and no native Swift integration boundary.
* Bad, because Chronicle would still need raw scratch or a new recovery contract.

### Option 7: Switch codec/container to FLAC or another self-synchronizing format

Revisit the storage format itself instead of replacing the current implementation.

* Good, because formats like FLAC have frame-level structure that can be more tolerant of truncation than ALAC-in-CAF.
* Good, because this may reduce reliance on an active compressed segment's final packet table.
* Bad, because it requires a new codec/container decision, new dependencies or lower-level wrappers, and a full STT parity re-run.
* Bad, because ADR-0002 already accepted ALAC-in-CAF after real-reference verification; switching now would re-open closed work.

## Decision

Chosen option: **Option 1: Keep current Apple-native sinks plus Chronicle-owned rotation and scratch**.

This is accepted because no surveyed Apple API, Swift library, or media pipeline replaces Chronicle's actual requirement set without changing the artifact model, adding a runtime process, or leaving the same custom recovery policy to implement anyway.

Chronicle should continue to use Apple APIs directly for commodity audio work and keep project-specific policy in small local components:

* `AVAudioFileALACSink` keeps ALAC/CAF encoding on the highest-level Apple writer that already passed the long-reference verification.
* `RotatingAudioSidecarSink` owns audio-duration segment boundaries for any file-backed sidecar.
* `CompositeAudioSidecarSink` keeps durable sidecar and scratch moving from the same input buffer stream.
* `RollingPCMScratchSink` remains the recovery and premium-STT tier because raw headerless PCM is the one artifact whose already-written bytes stay useful without container finalization.

This decision does not claim the current implementation is complete. It claims replacing it with a framework now would not improve robustness enough to justify dependency, container, TCC, or parity risk.

## Robustness and efficiency gaps to close in Chronicle

Current approach is the best local boundary, but these gaps remain product work:

1. **Sample-exact continuity proof.** Add a synthetic test that writes the same PCM sequence through a non-rotating ALAC sink and a rotating ALAC sink, decodes/concatenates outputs, and asserts byte-identical PCM.
2. **Scratch export/repair command.** Implement `chronicle scratch-export` or extend `chronicle repair` to read `audio/scratch/<session>/format.json` plus `.pcm` segments and emit WAV/ALAC without manual ffmpeg commands.
3. **Power-loss durability policy.** Decide whether scratch should `fsync` on rotate, on a fixed interval, or never. Current evidence is strong for process crash after successful writes, not for kernel panic/power loss before filesystem flush.
4. **Sequential fan-out measurement.** Measure worst-case append latency for ALAC + scratch under real mic/sysaudio loads. If needed, move child sink writes behind bounded queues while preserving backpressure and ordering.
5. **Scratch allocation profile.** Keep current `Data` allocation per append for 16 kHz mono, but profile before higher sample rates or multi-channel capture become defaults.
6. **CAF tail repair research.** FR-8 should determine whether active ALAC CAF can be repaired by walking `kuki`/`pakt`/`data` chunks and truncating to the last decodable packet. If not, scratch export is the primary recovery path.

## Revisit triggers

Reopen this ADR only if one of these becomes true:

* **Active compressed segment must be directly playable after hard crash.** Then evaluate fragmented MP4/CMAF with `AVAssetWriter` or GStreamer `qtmux`, accepting that this is a container migration.
* **ALAC-in-CAF shows unfixable tail-loss or performance issues in live use.** Then evaluate FLAC or another self-synchronizing lossless container with fresh WER/storage tests.
* **A maintained Swift package ships all of: live `AVAudioPCMBuffer` ingestion, ALAC/CAF or accepted replacement output, time-based rotation, raw PCM scratch/ring retention, crash-recovery/export hooks, and Swift-concurrency-safe backpressure.** Current surveyed packages do not.
* **Chronicle grows into a general media-capture product.** Then a capture framework like swift-capture-kit may become a better abstraction than the current small sidecar protocol.

## Consequences

### Positive

* Keeps the verified ALAC-in-CAF parity and storage evidence from ADR-0002 intact.
* Avoids ffmpeg/GStreamer runtime dependency, subprocess supervision, and extra TCC identity problems.
* Keeps robustness policy explicit and testable in repo code instead of hidden in a framework whose target use case differs.
* Keeps future migration path clear: if active-fragment playability becomes hard requirement, migrate container deliberately rather than accidentally through a library swap.

### Negative

* Chronicle owns the custom code that is easy to get subtly wrong: rotation continuity, scratch ring correctness, TTL pruning, and repair/export tooling.
* Current active ALAC CAF segment can still lose finalization metadata after hard kill. Scratch mitigates audio loss but does not make the CAF itself magically valid.
* There is no dependency to blame for sidecar bugs; tests and receipts must prove the policy code.
* Some potentially better robustness properties require a future container change, not local refactor.

### Neutral

* ffmpeg remains useful for verification, manual scratch recovery, and export/rewrap. It is not a daemon-time dependency.
* AudioKit, SFBAudioEngine, and similar libraries remain valid future tools for DSP, playback, metadata, or offline conversion. They do not replace the live sidecar path.
* `AVAssetWriter`/GStreamer robust MP4 approaches remain documented alternatives, but they belong behind a separate ADR because they change artifact semantics.

## Evidence Summary

### Apple APIs

* [`AVAudioFile`](https://developer.apple.com/documentation/avfaudio/avaudiofile) is a sequential file abstraction over `AVAudioPCMBuffer` read/write. It is the correct high-level writer for ALAC-in-CAF, but it does not rotate files or create scratch rings.
* [`AVAudioFile.close()`](https://developer.apple.com/documentation/avfaudio/avaudiofile/close\(\)) exists to control when write-side headers are updated. This confirms active compressed files still have finalization semantics.
* [`AVAudioRecorder`](https://developer.apple.com/documentation/avfaudio/avaudiorecorder) records to a file with record/pause/stop/duration controls. It does not meet Chronicle's per-buffer fan-out, rotation, or scratch requirements.
* [`AVAssetWriter.preferredOutputSegmentInterval`](https://developer.apple.com/documentation/avfoundation/avassetwriter/preferredoutputsegmentinterval), [`AVAssetWriterDelegate`](https://developer.apple.com/documentation/avfoundation/avassetwriterdelegate), and [`AVFileTypeProfile`](https://developer.apple.com/documentation/avfoundation/avfiletypeprofile) support segmented HLS/CMAF/fMP4-style workflows, not ALAC-in-CAF sidecars.
* [`kAudioFilePropertyDeferSizeUpdates`](https://developer.apple.com/documentation/audiotoolbox/kaudiofilepropertydeferssizeupdates) documents the trade-off between frequent header updates and speed; disabling updates is faster but less safe. This helps explain why relying on container finalization alone is not enough.
* Apple's archived [CAF overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_overview/CAF_overview.html) explains CAF chunk structure. CAF is better than RIFF/WAV for some streaming cases, but ALAC still has variable packet metadata that must be represented correctly for broad readers.

### Swift libraries

* [AudioKit](https://github.com/AudioKit/AudioKit) is a mature Swift audio synthesis/processing platform. It does not provide Chronicle's segmented ALAC CAF + raw scratch sidecar primitive.
* [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) is a mature audio playback/conversion/metadata library. It is not a live sidecar sink with Chronicle recovery semantics.
* [swift-capture-kit](https://github.com/atelier-socle/swift-capture-kit) is the closest surveyed framework with file output and rotation concepts, but it is new, low-adoption, uses a broader capture-session abstraction, and does not provide Chronicle's raw PCM scratch/recovery tier.
* [AudioConvertionKit](https://github.com/beshkenadze/AudioConvertionKit) and small Opus/CAF converters are offline conversion tools, not live daemon sidecar replacements.

### Media pipelines

* [ffmpeg segment muxer](https://ffmpeg.org/ffmpeg-formats.html#segment_002c-stream_005fsegment_002c-ssegment) can segment media and remains useful for verification/export, but a daemon-time ffmpeg process adds supervision/backpressure/install/TCC risk and does not remove the need for scratch.
* [GStreamer `splitmuxsink`](https://gstreamer.freedesktop.org/documentation/multifile/splitmuxsink.html) provides mature split-by-time/size media writing. It is not a Swift-native drop-in and its strongest robust-finalization story is for MP4-like muxers.
* [GStreamer `qtmux`](https://gstreamer.freedesktop.org/documentation/isomp4/qtmux.html) documents robust muxing by reserving/re-writing headers so interrupted MP4 output can remain playable. This is the strongest future option if Chronicle accepts a container change.

## Related

* **PRD**: [`docs/prd/PRD-001-resilient-multi-source-daemon.md`](../prd/PRD-001-resilient-multi-source-daemon.md)
* **ADRs**: [ADR-0001](ADR-0001-modular-pipeline-architecture.md), [ADR-0002](ADR-0002-audio-storage-format.md), [ADR-0004](ADR-0004-tahoe-system-audio-capture.md)
* **Implementation**: `Sources/Chronicle/Core/Sinks/AVAudioFileALACSink.swift`, `Sources/Chronicle/Core/Sinks/AudioSidecarCombinators.swift`, `Sources/Chronicle/Core/Sinks/RollingPCMScratchSink.swift`, `Sources/Chronicle/Subcommands/Mic.swift`, `Sources/Chronicle/Subcommands/SysAudio.swift`
