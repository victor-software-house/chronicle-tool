# Live-mic daemon (real-time, multi-sidecar) — receipts + design

Date: 2026-05-13.
Binary: `.build/release/chronicle mic`.
Status: **running in production as a long-lived background process** under
the Pi `process` tool (`proc_4` at time of writing).

## What it does

A single Swift 6 binary that:

1. Taps the default microphone via `AVAudioEngine.inputNode` (48 kHz Float32).
2. Resamples each buffer to the analyzer's preferred PCM (16 kHz Int16
   mono) via `AVAudioConverter`.
3. Feeds the resampled buffers into `SpeechAnalyzer.start(inputSequence:)`
   over a hand-built `AsyncStream<AnalyzerInput>`.
4. Consumes `SpeechTranscriber.results` with the `.progressiveTranscription`
   preset — volatile updates every ~150 ms, finals on phrase boundaries.
5. Optionally writes four sidecar streams **from the same tap**:
   - `--save-audio <wav>` — lossless 16 kHz Int16 mono WAV.
   - `--live <file>` — rolling snapshot (finals stack + `→ volatile`),
     atomic-rewrite every event (~150 ms cadence).
   - `--append <file>` — timestamped final-only append log (`[ISO]
     <text>`), durable audit trail.
   - `-o <json>` — full event trace, flushed on graceful stop.

## Why all four sidecars

| Sidecar | Reader behaviour | Cost |
|---|---|---|
| `audio/session.wav` | re-runnable through offline `transcribe`, `diarize`, premium STT, archival | ~115 MB / h |
| `live.md` | tail-able in VSCode / `tail -F`; updates every ~150 ms; **feels live** | ~1 KB rewritten per event |
| `finals.md` | machine-parseable audit log; survives `SIGTERM` even if the JSON trace is lost | one append per phrase |
| `trace.json` | full per-event trace (volatile + final, wall-clock offsets, audio ranges) for post-hoc analysis | written on graceful stop |

Each sidecar costs near-zero per stream because the work is shared with the
SpeechAnalyzer call — the buffer comes off the tap once, goes to the
converter once, and fans out to (a) the analyzer's `AsyncStream` and (b)
the `AVAudioFile`. The text-side sidecars are cheap rewrites of < 4 KB
files.

## Resource footprint (measured)

| Metric | Value | Notes |
|---|---:|---|
| CPU (sustained while talking) | **0.5 – 0.8 %** of one core | M4 Pro, 14 cores. Tap + convert + stream + file writes. Actual model runs off-process on the ANE via XPC. |
| RSS | **30 MB** | mostly AVFoundation + Foundation + AsyncStream buffers; the speech model is mmap'd from `/System/Library/AssetsV2/…` and shared across all instances |
| Disk I/O — audio | **32 KB/s** = 115 MB/h | 16 kHz Int16 mono lossless |
| Disk I/O — text | ~10 KB/s combined | `live.md` atomic rewrites + `finals.md` appends |
| Volatile latency | **~150 ms** | tap → ANE → result stream → file rewrite |
| Final latency | **5 – 30 s** | phrase boundary, decided by the model |

## Scaling math for parallel daemons

| Resource | Per-stream | Hard ceiling on M4 Pro / 48 GB |
|---|---:|---|
| Mic input devices | 1 per daemon | usually the actual bottleneck — limited by CoreAudio device count |
| RAM | 30 MB | 48 GB ÷ 30 MB = ~1,600 instances |
| CPU | 0.5-0.8 % per stream | one perf core saturates at ~125-200 streams |
| ANE bandwidth | small fraction | offline `transcribe` headroom = 273 × realtime → ~250+ simultaneous real-time streams plausible |
| File I/O | trivial | NVMe handles thousands easily |

For chronicle's "many mics" scenario:
- 1 daemon per audio source.
- Use a CoreAudio aggregate device to fan out multiple mics, or a virtual
  loopback (BlackHole / Loopback) to capture system audio.
- The actual chokepoint is the audio-device count, not the silicon.

## Implementation receipts (the working source)

### Apple's stream contract

```swift
struct Result {
  var text: AttributedString
  var range: CMTimeRange   // audio span this result covers
  var isFinal: Bool         // false while revising; true once committed
}
```

The model emits many results for the same audio range with
`isFinal = false`, each one a refinement. When it commits, one final fires
and the model moves on. That's the native auto-correct.

### Rolling buffer (actor for thread safety)

```swift
actor LiveState {
  var finals: [String] = []
  var currentVolatile: String = ""

  func addFinal(_ s: String) {
    finals.append(s)
    currentVolatile = ""
  }
  func setVolatile(_ s: String) { currentVolatile = s }
  func snapshot() -> String {
    let block = finals.joined(separator: "\n")
    if currentVolatile.isEmpty { return block }
    if block.isEmpty            { return "→ \(currentVolatile)" }
    return block + "\n→ " + currentVolatile
  }
}
```

### Consumer loop

```swift
for try await result in transcriber.results {
  let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
  if text.isEmpty { continue }

  if result.isFinal {
    await liveState.addFinal(text)
    if let url = appendURL {
      let line = "[\(iso.string(from: .now))] \(text)\n"
      if let h = try? FileHandle(forWritingTo: url) {
        try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
        try? h.close()
      }
    }
  } else {
    await liveState.setVolatile(text)
  }

  if let url = liveURL {
    let snap = await liveState.snapshot()
    try? snap.write(to: url, atomically: true, encoding: .utf8)
  }
}
```

`String.write(to:atomically:true)` is write-temp-then-`rename(2)` — readers
never see a half-written file.

### Audio fan-out from the tap

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [analyzerFormat, audioFileBox] buffer, _ in
  // ... resample to analyzerFormat into `converted` ...
  builder.yield(AnalyzerInput(buffer: converted))   // → SpeechAnalyzer
  if let file = audioFileBox.file {                  // → WAV sidecar
    try? file.write(from: converted)
  }
}
```

Same buffer goes to both the analyzer's stream and the WAV file. One tap,
multiple consumers, no copy beyond the converter's already-allocated
output buffer.

### Graceful shutdown on SIGINT / SIGTERM

```swift
let intSource  = DispatchSource.makeSignalSource(signal: SIGINT)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM)
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let waitOnSignal = Task {
  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    let once = OneShotResume(continuation: cont)
    intSource.setEventHandler  { once.fire() }
    termSource.setEventHandler { once.fire() }
    intSource.resume(); termSource.resume()
  }
}
_ = await waitOnSignal.value
```

Both signals trigger a single `once.fire()` and the daemon does:

```swift
engine.stop()
inputNode.removeTap(onBus: 0)
builder.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
try await consumeTask.value
// write trace JSON
```

`finalizeAndFinishThroughEndOfInput` flushes any in-flight volatile state
into one last final before the analyzer closes, so `finals.md` and the
JSON trace stay consistent.

## File-locking posture

| File | Concurrency safety |
|---|---|
| `live.md` | atomic rename per write; no lock needed for single writer + arbitrary readers |
| `finals.md` | single writer assumed; `FileHandle.seekToEnd` + `write` is **not** atomic across processes |
| `audio/session.wav` | single writer; `AVAudioFile.write(from:)` is serialised by the audio thread |
| `trace.json` | written once at shutdown, atomic |

For a single chronicle daemon on a given audio device, safe. If we ever
spawn multiple writers to the same file, upgrade `finals.md` to
`open(O_APPEND) + flock(LOCK_EX)`. Not needed today.

## Live demo (proc_4 receipts, in real time)

Started:

```text
[mic] locale=pt_BR preset=progressiveTranscription
[mic] analyzerFormat=<AVAudioFormat: 1 ch, 16000 Hz, Int16>
[mic] mic format=<AVAudioFormat: 1 ch, 48000 Hz, Float32>
[mic] saving audio to ~/Movies/pi-captures/live-mic/audio/session.wav
[mic] appending finals to ~/Movies/pi-captures/live-mic/finals.md
[mic] live transcript file: ~/Movies/pi-captures/live-mic/live.md
[mic] engine started
```

Snapshot of `live.md` while operator is narrating a Portuguese aviation
documentary in real-time:

```text
Todos vão ser substituídos por gravadores novos digitais e a Bianca não fez
isso. Esses gravadores antigos tinham uma capacidade de armazenamento de
dados limitada e um histórico de problemas. Segundo a investigação também
houve falhas na comunicação dos controladores que mesmo depois
da catastrófica comunicação do copiloto sobre o combustível não aprofundou
o assunto e de certo modo contribuiu pro acidente mesmo que indiretamente.
…
→ mais Wyby. faça com que o inglês se torne algo natural na sua vida
```

Finals committed at 21:50:18.774Z, 21:50:38.942Z, 21:50:59.003Z, then
several more — model commits roughly every 15-25 s of continuous speech.

Daemon ran continuously for >9 minutes on one previous incarnation
(proc_3) without leaks or drift.

## What still needs wiring

1. **Live diarization** (`SortformerDiarizer` from FluidAudio): fan a second
   consumer off the same tap, merge speaker labels with the transcript by
   `audioRange`. Output: each final transcript line gets a `speakerId`.
2. **System-audio sidecar** (`ScreenCaptureKit` audio tap, macOS 14.2+):
   new `chronicle sysaudio` subcommand using `SCStream` with the same
   pipeline as `mic`. Needs `NSScreenCaptureUsageDescription` entitlement.
3. **Cross-stream merge** at the writer level: when `mic` + `sysaudio` are
   running in parallel, a thin `chronicle merge` subcommand interleaves
   their finals.md outputs into a single chronological transcript.
4. **Language auto-detect**: run `NLLanguageRecognizer` on the first few
   finals; switch SpeechTranscriber locale automatically once confident
   (the current `--locale` flag is fine but requires the operator to know
   what they'll speak).
5. **Foundation Models live tagging**: on each new final, fire a
   `chronicle tag` pass over the cumulative transcript so the operator
   gets running topic + entity + action tags as they talk.

## Decisions confirmed

- Single Swift binary, one subcommand per Tahoe framework, sidecars
  composed via shell.
- One AVAudioEngine tap, fan-out in the closure — no second tap, no
  duplicate buffers.
- Atomic-rename for the live snapshot; append for the durable log; raw
  WAV for archival.
- All on-device, $0 per inference, ANE-accelerated.
