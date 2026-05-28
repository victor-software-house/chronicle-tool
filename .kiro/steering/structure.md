# Structure Steering

## Repository Shape

Chronicle is one SwiftPM executable with modular internals:

```text
Sources/Chronicle/
├── Chronicle.swift
├── Subcommands/        # thin ArgumentParser orchestration veneers
└── Core/               # reusable implementation domains
    ├── Audio/
    ├── Diarize/
    ├── LLM/
    ├── Runtime/
    ├── Sinks/
    └── Speech/
Tests/ChronicleTests/   # Swift Testing, grouped by Core/Subcommands domain
docs/                   # legacy/current PRD, ADR, architecture plans, status
.kiro/                  # Kiro steering and feature specs for new governed work
```

## Architectural Boundaries

- `Subcommands/*` should stay thin: parse CLI flags, compose Core protocols, and handle operator-visible output.
- `Core/Audio/*` owns live audio source mechanics, conversion, fan-out, and tap lifecycle.
- `Core/Sinks/*` owns transcript/audio sidecar persistence; avoid inline file IO in subcommands except for concise operator messages.
- `Core/Speech/*` owns transcriber setup, locale policy, latency monitoring, and speech-specific helpers.
- `Core/Diarize/*` owns streaming/offline speaker labeling.

## Naming and Test Patterns

- New reusable behavior gets a small Core type plus focused Swift Testing coverage under the matching `Tests/ChronicleTests/<Domain>/` folder.
- New subcommands live in `Sources/Chronicle/Subcommands/` and must be registered in `Chronicle.swift`.
- Feature specs under `.kiro/specs/<feature>/` should govern new behavior before implementation. Existing `docs/prd`, `docs/adr`, and `docs/architecture` remain historical/source references until explicitly migrated.

## Change Rules

- Prefer extending existing protocols over adding parallel pipelines.
- Avoid compatibility fallbacks for states no current producer creates.
- Update docs/specs in the same change when runtime behavior or operator workflow changes.

---
_Structure guidance should let a fresh contributor place new code without reading every file._
