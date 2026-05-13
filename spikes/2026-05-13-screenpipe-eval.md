# POC-12 — screenpipe evaluation (deferred install)

Date: 2026-05-13.
Status: **DEFERRED**. Not installed today.

## Current state of screenpipe

- Active project: `github.com/mediar-ai/screenpipe`, brand `screenpi.pe`.
  Open-source 24/7 screen + audio + transcript chronicler.
- Marketed: integrated Apple Intelligence on Tahoe (2026-02-07 blog).
- Brew formula `screenpipe` is **deprecated** (will be disabled 2026-08-25,
  brew flagged "does not build"). Install path therefore is the **desktop
  app** download from `https://screenpi.pe/onboarding` or the CLI from
  the GitHub repo (Rust build).

## Why deferred

- Installing the desktop app requires TCC perms (Screen Recording,
  Microphone, Accessibility) — same set we already granted to our DIY
  stack. Running both 24/7 would double the recording surface and confuse
  the privacy posture audit we want to keep clean.
- The Rust CLI build is a non-trivial dependency to wire (Cargo, FFmpeg,
  Tesseract, custom Whisper toolchain). Not worth the time before we know
  whether screenpipe's bundled STT beats our Apple SpeechTranscriber path,
  which it almost certainly does not because screenpipe relies on Whisper
  variants, not Apple's new Tahoe `SpeechTranscriber`.
- We have just validated the full Tahoe stack here (transcribe / diarize /
  classify / ocr / translate, all on-device, ANE-accelerated). Screenpipe
  buys us less than it would have a month ago.

## What screenpipe would still be useful for

- Reference implementation of the **storage tier + search UX** that
  chronicle eventually needs.
- An out-of-the-box **MCP server** exposing screen + audio context to
  other AI agents.
- A control point for the "is my DIY pipeline actually better than the
  popular alternative?" answer.

## When to revisit

Revisit if any of these become true:

- Our DIY 24/7 capture is not stable after 7 days of running.
- Operator wants a polished search UI rather than CLI greps over JSONL.
- We need the MCP integration for live agent context.

In that case, install the desktop app, run it for 24h, measure: disk
growth, CPU, transcript quality (vs our `chronicle transcribe` output on
the same audio), OCR quality (vs our `chronicle ocr` output on the same
keyframe), and the MCP surface.

## Decision

Do not install screenpipe today. Continue with our DIY stack. The current
chronicle binary already does:

- 103 × realtime offline STT (Apple SpeechAnalyzer)
- 115 × realtime diarization (FluidAudio)
- 571 × realtime speech-gate (Apple SoundAnalysis)
- ~4 s per screenshot document OCR (Apple Vision)
- on-device translation (gated on language packs)
- structured content tagging + summarization (gated on Apple Intelligence)

Screenpipe would not improve any of those numbers; it would only add
storage + search + MCP plumbing on top. We can build those ourselves when
we need them, on the same Tahoe primitives.
