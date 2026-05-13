---
title: "Locale resolution policy for live audio sources"
adr: ADR-0003
status: Proposed
date: 2026-05-13
prd: "PRD-001-resilient-multi-source-daemon"
decision: "Three modes: fixed (default off-auto), auto with explicit candidate set (default daemon mode), auto with full SpeechTranscriber-supported set (opt-in only)"
---

# ADR-0003: Locale resolution policy for live audio sources

## Status

Proposed

## Date

2026-05-13

## Requirement Source

- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md`
- **Decision Point**: §5 FR-6 (locale auto-detect via `--locale auto`) and
  §6 NFR "Resilience: …operator confidence in unattended capture". This
  ADR fixes the *policy* (which languages may be picked, when, under what
  hysteresis); FR-6 stays as the *requirement* (auto-detect exists).

## Context

The live transcriber subcommands (`mic`, future `sysaudio`, future `live`
file replay) accept `--locale`. The spike pinned the locale (e.g.
`--locale pt-BR`); changing it required restarting the daemon. PRD-001
FR-6 promised `--locale auto` so 24/7 capture can keep up when the
operator switches languages between calls or paragraphs.

Naïve auto-detect is dangerous for a 24/7 chronicle:

- Apple's `NLLanguageRecognizer` returns probabilities across **all**
  supported written languages, including Russian, Mandarin, Arabic,
  Hindi, etc. On noise, music, single foreign loanwords, or silence
  followed by one cough, the top hypothesis can flip wildly.
- `SpeechTranscriber.supportedLocales` is large. A daemon left running
  overnight on background TV / podcast / typing noise has thousands of
  opportunities to pick a wrong locale.
- Operators care about a narrow language set (this one: English +
  Brazilian Portuguese). A correct detection inside that set is useful;
  any detection outside it is noise.
- Even within the safe set, false flips mid-call are operator-visible
  garbage in `live.md` until the next correct detection arrives.
- The cost of switching locales is non-trivial: re-init the
  `SpeechTranscriber` at the new locale + asset install check.

The user's stated requirement is explicit:

> "Just make sure the locale auto-detection is robust, we can disable
> at any time or can at least restrict the possible languages that
> could be considered (pt & english for instance) … we don't want
> crazy random russian words creeping up."

So the policy must support: **disable**, **restrict**, and a strong
hysteresis profile when enabled.

## Decision Drivers

- **PRD-001 NFR "operator confidence in unattended capture".** A daemon
  left running overnight must not produce garbage Russian transcripts
  because of TV noise; if it does, the daemon is worse than useless.
- **Real-language profile of the operator.** Two daily-driver languages
  (en-US, pt-BR), occasional Spanish on calls, rare French/Italian.
  Russian / Arabic / Mandarin / Hindi / etc. are noise candidates only.
- **Operator override at any time.** A pin must always win; the auto
  mode must never override `--locale en-US`.
- **NLLanguageRecognizer is well-calibrated within a constrained
  candidate set** but degrades on the full unrestricted set under noise.
  The Apple-recommended pattern is to constrain candidates with
  `setLanguageConstraints([...])`.
- **Switch cost.** Re-initialising `SpeechTranscriber` mid-stream costs
  ~100-300 ms and may drop in-flight buffers. Flips must be rare and
  high-confidence; oscillation is unacceptable.
- **Symmetry across subcommands.** `mic`, `sysaudio`, and `live` must
  all accept the same `--locale` grammar. No subcommand may interpret
  it differently.

## Considered Options

### Option 1: Pin-only (no auto)

Keep the spike behaviour: `--locale <bcp47>` mandatory. Implement no
auto-detect at all.

- Good, because zero risk of misdetection.
- Good, because zero implementation cost.
- Bad, because FR-6 is dropped — every cross-language session requires
  restarting the daemon, defeating the chronicle's value proposition for
  bilingual operators.

### Option 2: Naïve auto over the full SpeechTranscriber locale set

Implement `--locale auto`. Feed every final into `NLLanguageRecognizer`
with no candidate constraint. Switch when the top hypothesis changes.

- Good, because maximally permissive — catches any language the
  transcriber actually supports.
- Bad, because **TV / podcast / typing noise + single loanwords flip
  the detector** to plausible-but-wrong candidates including languages
  the operator never speaks.
- Bad, because the failure mode is operator-confidence-destroying:
  `live.md` and `finals.md` accumulate garbage that survives in the
  chronicle forever.
- Disqualifying for 24/7 unattended use.

### Option 3: Auto with mandatory candidate-set restriction + hysteresis

Implement three modes for `--locale`:

```text
--locale en-US                  # mode A: fixed (pin; no detection)
--locale auto                   # mode B: auto with default safe set
--locale auto:en-US,pt-BR,es-ES # mode C: auto with explicit set
--locale auto:*                 # mode D (opt-in only): full supported set
```

- **Mode A (fixed)** is the default for an unattended daemon when the
  operator pins a single language explicitly. No detection runs at all.
- **Mode B (auto, default safe set)** is the default for `--locale auto`.
  Candidates = the operator-configured "primary languages" list, read
  from a config file (`~/.config/chronicle/locales.json`) or, if the
  config is absent, the built-in safe default `[en-US, pt-BR]`.
- **Mode C (auto, explicit set)** lets the operator override per-run
  with `--locale auto:en-US,pt-BR,es-ES`. Candidates limited to the
  listed set.
- **Mode D (auto, full set)** is opt-in only via `--locale auto:*` (or
  equivalently `--locale auto:any`). Documented as "for research or
  multilingual environments where the safe set is too restrictive";
  not the default, never picked silently.

Hysteresis applies to modes B/C/D:

- `NLLanguageRecognizer` is configured with
  `setLanguageConstraints([...])` to the candidate set.
- The detector runs only on **finals** (volatile is too noisy).
- A switch requires **N consecutive finals** (default 3) agreeing on
  the same locale, **with confidence ≥ threshold** (default 0.70).
- A switch is **suppressed for `cooldownSeconds`** (default 30 s)
  after the previous switch, regardless of detector evidence.
- A switch is **suppressed if fewer than `minimumFinalChars`**
  (default 30) have been observed at the new locale — single
  loanwords don't trigger a flip.
- Initial locale = first candidate in the set (so `[en-US, pt-BR]`
  starts in `en-US`).

Failure-mode safety net:

- All thresholds + the candidate set are CLI-overridable for
  experimentation (`--locale-confidence`, `--locale-min-finals`,
  `--locale-cooldown-sec`, `--locale-min-chars`). Defaults are the
  conservative profile above.
- `--locale auto:*` requires the long form (no shortcut), so accidental
  unrestricted runs are unlikely.

- Good, because **prevents the "random Russian" failure mode** by
  construction — Russian is never in the candidate set unless the
  operator explicitly puts it there.
- Good, because **operator can disable detection** by pinning a locale
  (`--locale en-US`). No "off switch" flag needed; the existing
  `--locale <bcp47>` mode is already the off switch.
- Good, because hysteresis prevents oscillation under noise + single
  loanwords.
- Good, because the default behaviour matches the operator's real
  language profile (`[en-US, pt-BR]`) without configuration.
- Good, because `NLLanguageRecognizer` is well-calibrated on small
  constrained candidate sets — the failure mode is large-set
  free-for-alls.
- Good, because operators with different language profiles can persist
  their safe set in `~/.config/chronicle/locales.json` once.
- Bad, because three modes + a config file is more surface than the
  spike's single `--locale <pin>`.
- Bad, because the safe-set defaults are this-operator-specific
  (en-US, pt-BR). Mitigated by the config file + the `auto:<list>`
  per-run override.

### Option 4: Online learning of operator-specific candidate set

Track which locales the operator actually uses over the last 30 days;
auto-build the safe set from observed history.

- Good, because zero config for adaptive operators.
- Bad, because it requires persistent state and a "training period"
  during which detection is degraded.
- Bad, because the operator's stated set (`[en-US, pt-BR]`) is small
  and stable — over-engineering for the problem.
- Deferred to a future ADR if usage justifies it. Not in PRD-001.

## Decision

Chosen option: **Option 3 — Auto with mandatory candidate-set
restriction + hysteresis**, because it is the only option that
satisfies all of the user's stated requirements simultaneously:

- Disables at any time: pin via `--locale en-US`.
- Restricts candidates: default `[en-US, pt-BR]`, override via
  `--locale auto:<list>` or `~/.config/chronicle/locales.json`.
- Prevents "random Russian" by construction (Russian never in the
  set unless explicitly added).
- Robust under noise via the 4-knob hysteresis (confidence floor,
  consecutive-finals threshold, cooldown, min-chars-at-new-locale).
- Implements FR-6 without compromising the NFR for operator
  confidence in unattended capture.

Option 1 was rejected because it drops FR-6. Option 2 was rejected
because it has the very failure mode the operator explicitly named.
Option 4 was deferred as out-of-scope for PRD-001.

## Configuration surface

| Knob | Default | Override |
|------|---------|----------|
| candidate set | `[en-US, pt-BR]` | `--locale auto:<list>` or `~/.config/chronicle/locales.json` |
| confidence floor | `0.70` | `--locale-confidence <float>` |
| consecutive-final threshold | `3` | `--locale-min-finals <int>` |
| switch cooldown | `30 s` | `--locale-cooldown-sec <int>` |
| min chars at new locale | `30` | `--locale-min-chars <int>` |
| initial locale | first candidate | implicit |

`--locale <bcp47>` (no `auto:` prefix) → mode A, all knobs ignored, no
detector runs.

`--locale auto:*` → mode D, full `SpeechTranscriber.supportedLocales`.
Documented as "research mode"; never picked silently.

## Consequences

### Positive

- Operator's primary failure-mode concern ("random Russian words
  creeping up") is impossible by default: Russian is never in the
  candidate set.
- Detection is robust on the small candidate set
  (`NLLanguageRecognizer` is well-calibrated for ≤ 5 candidates).
- Disable is the existing pin syntax — no new flag, no surprise.
- Hysteresis defaults are conservative enough that on borderline
  audio the daemon stays at the current locale rather than oscillating.
- Per-run override via `--locale auto:en-US,pt-BR,es-ES` covers
  one-off multilingual sessions without persisting state.
- Symmetric across `mic` / `sysaudio` / `live` — same flag grammar,
  same `LocaleResolver` instance under the hood.

### Negative

- The default safe set is operator-specific (`[en-US, pt-BR]`). Another
  user installing chronicle from source needs to either accept those
  defaults, override per-run with `--locale auto:<their-list>`, or
  drop a `~/.config/chronicle/locales.json`. Mitigation: documented in
  README; small surface; not a 24/7 chronicle hazard since the
  command fails fast on the first non-listed final.
- Four CLI knobs + a config file is more surface than the spike.
  Mitigation: every knob has a sensible default; the daemon runs fine
  with only `--locale auto`.
- The `--locale auto:*` mode does exist (Option 2 in disguise) and is
  reachable by operators who explicitly want it. Mitigation: the
  long form discourages accidents; documented as "research mode".

### Neutral

- `~/.config/chronicle/locales.json` becomes the first chronicle
  config file. Future config (audio scratch TTL, default codec, etc.)
  can live in the same file. Schema decided when first written.
- The detector runs on finals only. Volatile-text detection is too
  noisy by an order of magnitude (single-token hypotheses); discarded
  by design.

## Related

- **PRD**: `docs/prd/PRD-001-resilient-multi-source-daemon.md` —
  FR-6 (auto-detect); §7 risk row "Language auto-detect false-flip"
  (this ADR is the mitigation).
- **ADRs**: [ADR-0001](ADR-0001-modular-pipeline-architecture.md) —
  `Core/Speech/LocaleResolver` plugs into the protocol-oriented core
  established there.
- **Implementation**: task **P4** (`LocaleResolver` + `--locale auto`
  + NL unit tests). Acceptance criteria updated to match this ADR.
