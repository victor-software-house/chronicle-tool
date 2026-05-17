# 2026-05-17 sidecar fanout profile

## Question

Does the default `CompositeAudioSidecarSink([AVAudioFileALACSink, RollingPCMScratchSink])`
need a queue/ring-buffer fanout layer, or is sequential `await sink.append(buffer)`
fast enough for current analyzer-format sidecar writes?

## Method

Compiled the exact sink source files with `swiftc -O` and a temporary profiler:

```sh
swiftc -O -o /tmp/chronicle_sidecar_profile \
  /tmp/chronicle_sidecar_profile.swift \
  Sources/Chronicle/Core/Sinks/AudioSidecarSink.swift \
  Sources/Chronicle/Core/Sinks/AudioSidecarCombinators.swift \
  Sources/Chronicle/Core/Sinks/AVAudioFileALACSink.swift \
  Sources/Chronicle/Core/Sinks/RollingPCMScratchSink.swift
/tmp/chronicle_sidecar_profile
```

Profiler shape:

- one reusable non-interleaved Float32 sine buffer per scenario
- default composite ALAC + raw scratch sink
- sequential `await sink.append(buffer)` timing
- local APFS temp directory
- no fsync beyond current `FileHandle.write` / `AVAudioFile.write`
- no live CoreAudio callback or `AsyncStream` contention

A SwiftPM debug harness also ran successfully, but release-ish `swiftc -O`
measurements below are the acceptance receipt.

## Results

| Scenario | Format | Audio/buffer | Appends | Avg append ms | p50 ms | p95 ms | p99 ms | Max ms | Wall/audio | Bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| analyzer mono | 16000 Hz / 1 ch / 160 frames | 10.00 ms | 2000 | 0.005 | 0.003 | 0.006 | 0.058 | 0.077 | 0.001x | 1680900 |
| hi-band stereo | 48000 Hz / 2 ch / 480 frames | 10.00 ms | 2000 | 0.027 | 0.010 | 0.156 | 0.182 | 0.253 | 0.003x | 9562139 |
| large callback | 48000 Hz / 2 ch / 1024 frames | 21.33 ms | 1000 | 0.042 | 0.012 | 0.134 | 0.153 | 0.296 | 0.002x | 10037422 |

Debug SwiftPM cross-check:

| Scenario | Format | Audio/buffer | Appends | Avg append ms | p50 ms | p95 ms | p99 ms | Max ms | Wall/audio | Bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| analyzer mono | 16000 Hz / 1 ch / 160 frames | 10.00 ms | 2000 | 0.036 | 0.033 | 0.048 | 0.093 | 0.159 | 0.004x | 1680900 |
| hi-band stereo | 48000 Hz / 2 ch / 480 frames | 10.00 ms | 2000 | 0.156 | 0.137 | 0.294 | 0.326 | 0.428 | 0.017x | 9562139 |
| large callback | 48000 Hz / 2 ch / 1024 frames | 21.33 ms | 1000 | 0.315 | 0.285 | 0.429 | 0.476 | 0.770 | 0.016x | 10037422 |

## Conclusion

No sidecar fanout queue/ring-buffer change is justified now.

The default analyzer-format path has large headroom:

- current mono analyzer path: p99 0.058 ms for 10 ms audio (~0.6% of buffer budget)
- synthetic 48 kHz stereo path: p99 0.182 ms for 10 ms audio (~1.8% of buffer budget)
- larger 1024-frame stereo callback: p99 0.153 ms for 21.33 ms audio (~0.7% of buffer budget)

Sequential fanout is not the present bottleneck. Keep `CompositeAudioSidecarSink`
unchanged until a real live capture profile shows sidecar writer pressure.

## Caveats / follow-ups

- This profiles sidecar append only, not full `CoreAudioTapSource` callback cost.
- If #72 adds per-append `fsync`, rerun this profile; durability policy can change
  write latency by orders of magnitude.
- #75 still needs scratch-specific allocation profiling. Current result includes
  scratch `Data` allocation cost but does not isolate it.
- #77 tail drain remains separate; this profile does not cover converter shutdown.
