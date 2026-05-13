# POC-7 — Vision document recognition + legacy OCR

Date: 2026-05-13.
Binary: `.build/release/chronicle ocr`.
Pattern: Tahoe-new `RecognizeDocumentsRequest` (default) and legacy
`RecognizeTextRequest` (`--text-only`).

## Goal

Compare Apple's new document-aware Vision API against the existing
`RecognizeTextRequest` on a real chronicle artifact (a screenshot of a
running browser + Pi window). Validate that table structure, paragraphs, and
reading order are picked up.

## Run

```sh
/usr/sbin/screencapture -x /tmp/ocr-test/screen.png

.build/release/chronicle ocr -i /tmp/ocr-test/screen.png -o out/screen.docs.json
.build/release/chronicle ocr -i /tmp/ocr-test/screen.png -o out/screen.text.json --text-only
```

## Result

| Mode | Lines | Elapsed | Tables | Reading order | Cost |
|---|---:|---:|---|---|---|
| `RecognizeDocumentsRequest` (Tahoe) | 133 | 4.04 s | ✔ (with row/col cells) | layout-aware | $0 (ANE) |
| `RecognizeTextRequest` (legacy) | 114 | 0.53 s | ✘ | left-to-right scanline | $0 (ANE) |

Image: 2992 × 1934 retina screenshot, ~720 KB PNG.

The new API explicitly emits table markers we keep in the JSON output:

```text
--- TABLE 12x3 ---
[0,0] General
[1,0] Team Management
...
[11,2] GitLab User
```

Document mode is roughly 8 × slower for an 8 % line-count increase, but the
table structure and paragraph grouping are worth far more than 4 seconds per
screenshot when the goal is "extract durable meaning from a screen frame".

## Decision

For chronicle:

- **Default to `RecognizeDocumentsRequest`** for keyframe OCR (every N
  seconds of capture, or on scene-change). Output keeps the table layout
  intact.
- **Use `RecognizeTextRequest` (`--text-only`)** when running on long video
  frame sequences where speed dominates and table structure is irrelevant.
- Combine with screen-capture KEY-frame extraction: don't run OCR per frame;
  run it on diffed/scene-change frames only.

## Output schema

```json
{
  "inputPath": "...",
  "imageWidth": 2992,
  "imageHeight": 1934,
  "mode": "RecognizeDocumentsRequest",
  "elapsedSeconds": 4.04,
  "lineCount": 133,
  "plainText": "…",
  "lines": [
    { "text": "API Keys", "confidence": 1.0, "bbox": null },
    { "text": "--- TABLE 12x3 ---", "confidence": 1.0, "bbox": null },
    { "text": "[0,0] General", "confidence": 1.0, "bbox": null }
  ]
}
```

Document mode does not emit per-line bounding boxes in this initial wrapper
(the API returns container regions rather than line rects); we keep `bbox`
nullable so the legacy mode can populate it.

## Reference

- `RecognizeDocumentsRequest` — [`developer.apple.com/documentation/Vision/RecognizeDocumentsRequest`](https://developer.apple.com/documentation/Vision/RecognizeDocumentsRequest)
- WWDC25 session 272 — "Read documents using the Vision framework"
- `DocumentObservation.Container.Table.cell(row:col:)` is the cell accessor
  (note: the docs sometimes show `at:column:`, but the Tahoe GA SDK uses
  `row:col:`). Verified against
  `MacOSX.sdk/.../Vision.swiftmodule/.../*.swiftinterface`.
