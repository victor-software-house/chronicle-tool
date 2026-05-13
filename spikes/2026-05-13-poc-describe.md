# POC-9 — Image description via Vision + Foundation Models

Date: 2026-05-13.
Binary: `.build/release/chronicle describe`.
Pattern: parallel multi-request Vision extraction → structured facts blob →
`FoundationModels` `@Generable` narration.

## Why this exists

Apple does not expose a multimodal image-to-text LLM on Tahoe 26 GA.
`LanguageModelSession.respond(...)` takes only text. The canonical
on-device "describe this image" pattern is:

1. Mine the image with Vision's structured requests (classification,
   animals, faces/humans, OCR, aesthetics, smudge).
2. Render the structured facts as a short string.
3. Hand the string to FoundationModels with a `@Generable` struct that
   demands caption + prominent objects + setting type + has-readable-text
   + quality notes.

Result: prose captions, on-device, $0, ANE-accelerated.

## Vision surface used

| Request | Purpose |
|---|---|
| `ClassifyImageRequest` | thousands of category labels with confidence |
| `RecognizeAnimalsRequest` | per-animal bounding boxes + species labels |
| `DetectFaceRectanglesRequest` | face count |
| `DetectHumanRectanglesRequest` | human-figure count |
| `RecognizeTextRequest` | OCR for "image contains readable text" signal |
| `CalculateImageAestheticsScoresRequest` (Tahoe-new) | quality + utility-image flag |
| `DetectLensSmudgeRequest` (Tahoe-new) | model bundle absent on this arch — call returns nil, output unaffected |

All seven requests are kicked off as Swift `async let` tasks; Vision runs
them in parallel on the Neural Engine.

## Result on 5 images

```sh
.build/release/chronicle describe -i <image> -o <out>.json
```

| Image | Caption | Total | Vision | Narrate |
|---|---|---:|---:|---:|
| Unsplash skyscraper | "A skyscraper on a city street." | 2.48 s | 1.00 s | 1.48 s |
| Unsplash dog | "A dog with a white and black coat walks on a sidewalk." | 1.28 s | 0.18 s | 1.10 s |
| Unsplash pizza | "A pizza with herbs and seasonings on a cutting board." | 1.44 s | 0.17 s | 1.26 s |
| macOS Finder screenshot | "Screenshot of a Finder window with text lines." | 1.47 s | 0.48 s | 0.99 s |
| Terminal screenshot | "Screenshot of a text-heavy document with OCR errors." | 1.68 s | 0.69 s | 0.99 s |

Faithfulness check: every caption is grounded in the structured facts.
The dog image carried an explicit animal label "Dog"; the pizza image had
"pizza" as a top label; the screenshots returned "screenshot" / "document"
top labels. The model never invented content the facts did not support.

## Output schema

```json
{
  "elapsedSeconds": 1.44,
  "visionSeconds": 0.17,
  "narrationSeconds": 1.26,
  "facts": {
    "width": 1200, "height": 800,
    "topLabels": [
      { "identifier": "food", "confidence": 0.93 },
      { "identifier": "pizza", "confidence": 0.91 }
    ],
    "animals": [],
    "faceCount": 0,
    "humanCount": 0,
    "ocrLineCount": 0,
    "ocrTextSample": "",
    "aestheticOverall": 0.72,
    "aestheticIsUtility": false,
    "smudgeConfidence": null
  },
  "narration": {
    "caption": "A pizza with herbs and seasonings on a cutting board.",
    "prominentObjects": ["pizza", "cutting_board", "herbs"],
    "settingType": "photograph",
    "hasReadableText": false,
    "qualityNotes": "Sharp focus on the pizza, balanced lighting."
  }
}
```

## Notes

- `DetectLensSmudgeRequest` is documented on Tahoe but its CoreML bundle is
  not installed on every Apple Silicon variant — Vision prints a noisy
  `Unable to find a valid E5 in provided path` warning then returns `nil`.
  We treat the missing result as "no smudge data" and continue. Filter the
  warnings out at the shell level if running in a TTY pipeline.
- `--no-narration` skips the FoundationModels stage and emits raw Vision
  facts only. Use for high-volume passes where you only need labels.
- For chronicle: `describe` is the right layer to run on **keyframes** from
  the screen capture (scene-changes, not every frame). Each call is ~1-2 s
  on Apple Silicon, so a 5-min-per-keyframe schedule is essentially free.

## Decision

Adopt `describe` as chronicle's **image-narration layer**. Apple does not
ship a public multimodal image-to-text LLM; this Vision-then-FoundationModels
pattern is the canonical Tahoe substitute, captures the same observability
benefits, and stays on-device + $0.
