# 2026-05-17 scratch allocation profile

## Question

Does `RollingPCMScratchSink` need reusable byte buffers, or is its current one
`Data` allocation per `append(_:)` cheap enough for current analyzer-format raw
scratch writes?

## Method

Compiled the scratch sink and a temporary profiler with `swiftc -O`:

```sh
swiftc -O -o /tmp/chronicle_scratch_alloc_profile \
  /tmp/chronicle_scratch_alloc_profile.swift \
  Sources/Chronicle/Core/Sinks/AudioSidecarSink.swift \
  Sources/Chronicle/Core/Sinks/RollingPCMScratchSink.swift
/tmp/chronicle_scratch_alloc_profile
```

Profiler shape:

- reusable non-interleaved Float32 sine buffer per scenario
- same interleave loop shape as `RollingPCMScratchSink.bufferToBytes(_:)`
- compared current `Data(count:)` allocation vs reusable `[Float]` storage
- compared `FileHandle.write` with per-append `Data` vs prebuilt `Data`
- measured current `RollingPCMScratchSink` writing to local APFS temp dir
- no fsync; #72 can change this result materially

`RollingPCMScratchSink` current allocation count is one `Data` per append:

- analyzer mono 16 kHz, 160 frames: 640 B/append
- 48 kHz stereo, 480 frames: 3840 B/append
- 48 kHz stereo, 1024 frames: 8192 B/append

## Results

| Scenario | Operation | Format | Audio/buffer | Bytes/append | Data allocs/append | Avg ms | p50 ms | p95 ms | p99 ms | Max ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| analyzer mono | Data alloc+interleave | 16000 Hz / 1 ch / 160 frames | 10.00 ms | 640 | 1 | 0.0002 | 0.0002 | 0.0002 | 0.0002 | 0.0004 |
| analyzer mono | preallocated interleave | 16000 Hz / 1 ch / 160 frames | 10.00 ms | 640 | 0 | 0.0002 | 0.0002 | 0.0002 | 0.0002 | 0.0091 |
| analyzer mono | Data alloc+write /dev/null | 16000 Hz / 1 ch / 160 frames | 10.00 ms | 640 | 1 | 0.0006 | 0.0006 | 0.0006 | 0.0008 | 0.0092 |
| analyzer mono | prebuilt Data write /dev/null | 16000 Hz / 1 ch / 160 frames | 10.00 ms | 640 | 0 | 0.0004 | 0.0004 | 0.0004 | 0.0005 | 0.0183 |
| analyzer mono | RollingPCMScratchSink temp APFS | 16000 Hz / 1 ch / 160 frames | 10.00 ms | 640 | 1 | 0.0017 | 0.0013 | 0.0032 | 0.0042 | 0.0360 |
| hi-band stereo | Data alloc+interleave | 48000 Hz / 2 ch / 480 frames | 10.00 ms | 3840 | 1 | 0.0005 | 0.0005 | 0.0005 | 0.0006 | 0.0122 |
| hi-band stereo | preallocated interleave | 48000 Hz / 2 ch / 480 frames | 10.00 ms | 3840 | 0 | 0.0006 | 0.0006 | 0.0007 | 0.0008 | 0.0132 |
| hi-band stereo | Data alloc+write /dev/null | 48000 Hz / 2 ch / 480 frames | 10.00 ms | 3840 | 1 | 0.0009 | 0.0009 | 0.0012 | 0.0013 | 0.0213 |
| hi-band stereo | prebuilt Data write /dev/null | 48000 Hz / 2 ch / 480 frames | 10.00 ms | 3840 | 0 | 0.0004 | 0.0004 | 0.0004 | 0.0005 | 0.0035 |
| hi-band stereo | RollingPCMScratchSink temp APFS | 48000 Hz / 2 ch / 480 frames | 10.00 ms | 3840 | 1 | 0.0037 | 0.0034 | 0.0043 | 0.0055 | 0.7766 |
| large callback | Data alloc+interleave | 48000 Hz / 2 ch / 1024 frames | 21.33 ms | 8192 | 1 | 0.0011 | 0.0010 | 0.0011 | 0.0012 | 0.0013 |
| large callback | preallocated interleave | 48000 Hz / 2 ch / 1024 frames | 21.33 ms | 8192 | 0 | 0.0013 | 0.0013 | 0.0014 | 0.0015 | 0.0190 |
| large callback | Data alloc+write /dev/null | 48000 Hz / 2 ch / 1024 frames | 21.33 ms | 8192 | 1 | 0.0014 | 0.0014 | 0.0015 | 0.0018 | 0.0372 |
| large callback | prebuilt Data write /dev/null | 48000 Hz / 2 ch / 1024 frames | 21.33 ms | 8192 | 0 | 0.0004 | 0.0004 | 0.0005 | 0.0005 | 0.0084 |
| large callback | RollingPCMScratchSink temp APFS | 48000 Hz / 2 ch / 1024 frames | 21.33 ms | 8192 | 1 | 0.0049 | 0.0044 | 0.0052 | 0.0073 | 0.5547 |

## Conclusion

Keep current allocation path.

For current analyzer-format scratch writes, per-append `Data` allocation is below
measurement relevance:

- analyzer mono alloc+interleave p99: 0.0002 ms for 10 ms audio
- 48 kHz stereo alloc+interleave p99: 0.0006 ms for 10 ms audio
- 1024-frame stereo alloc+interleave p99: 0.0012 ms for 21.33 ms audio

Full `RollingPCMScratchSink` temp-APFS p99 stayed tiny:

- analyzer mono: 0.0042 ms for 10 ms audio
- 48 kHz stereo: 0.0055 ms for 10 ms audio
- 1024-frame stereo: 0.0073 ms for 21.33 ms audio

Reusable storage does not win meaningfully in these cases. It would add state and
complexity to a single-writer sink without measurable benefit.

## Caveats / follow-ups

- This is not a durability profile. #72 fsync policy can dominate write latency.
- This is not a full CoreAudio callback profile. It only covers scratch byte
  conversion/write.
- If Chronicle later adds source-native hi-fi storage despite #79 deferral,
  rerun with larger channel counts / sample rates / bit depths.
- If `RollingPCMScratchSink` moves into a realtime callback instead of the
  current `AsyncStream` consumer, revisit preallocation.
