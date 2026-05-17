#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jiwer>=3.0.0"]
# ///
"""
Word Error Rate calculator for chronicle PRD-001 P11 parity verification (#50).

Computes WER between a reference transcript (`--ref`) and a hypothesis transcript
(`--hyp`). Both files are plain UTF-8 text. Applies a standard normalisation
chain — lowercase, strip punctuation, collapse whitespace — before scoring so
the comparison is robust to trivial spacing or punctuation differences between
the WAV and Opus round-trip runs of SpeechAnalyzer.

Output (single line, machine-parseable):

    WER=0.0123 N=618 S=5 D=2 I=1 hits=610

Exit code is 0 on success regardless of WER. Caller (verify-opus-parity.sh)
applies the ≤ 1 % acceptance gate.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import jiwer  # type: ignore[import-untyped]


def normalise(text: str) -> str:
    transform = jiwer.Compose(
        [
            jiwer.ToLowerCase(),
            jiwer.RemovePunctuation(),
            jiwer.RemoveMultipleSpaces(),
            jiwer.Strip(),
            jiwer.ReduceToListOfListOfWords(),
        ]
    )
    return transform(text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", required=True, help="reference transcript path")
    parser.add_argument("--hyp", required=True, help="hypothesis transcript path")
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit a JSON object instead of the one-line summary",
    )
    args = parser.parse_args()

    ref_text = Path(args.ref).read_text(encoding="utf-8")
    hyp_text = Path(args.hyp).read_text(encoding="utf-8")

    out = jiwer.process_words(
        ref_text,
        hyp_text,
        reference_transform=jiwer.Compose(
            [
                jiwer.ToLowerCase(),
                jiwer.RemovePunctuation(),
                jiwer.RemoveMultipleSpaces(),
                jiwer.Strip(),
                jiwer.ReduceToListOfListOfWords(),
            ]
        ),
        hypothesis_transform=jiwer.Compose(
            [
                jiwer.ToLowerCase(),
                jiwer.RemovePunctuation(),
                jiwer.RemoveMultipleSpaces(),
                jiwer.Strip(),
                jiwer.ReduceToListOfListOfWords(),
            ]
        ),
    )

    n = max(out.substitutions + out.deletions + out.hits, 1)
    payload = {
        "wer": out.wer,
        "n_ref": out.substitutions + out.deletions + out.hits,
        "substitutions": out.substitutions,
        "deletions": out.deletions,
        "insertions": out.insertions,
        "hits": out.hits,
        "ref_path": args.ref,
        "hyp_path": args.hyp,
    }

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(
            f"WER={out.wer:.4f} N={payload['n_ref']} "
            f"S={out.substitutions} D={out.deletions} I={out.insertions} "
            f"hits={out.hits}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
