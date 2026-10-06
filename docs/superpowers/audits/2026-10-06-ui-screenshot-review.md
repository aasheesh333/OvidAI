# UI screenshot review — objective metrics only (2026-10-06)

## Purpose and hard limit

Fifteen UI screenshots (`/tmp/opencode/ui-finish-01.png` … `ui-finish-15.png`)
were captured from the finished UI, but the agent performing this audit had **no
vision capability** and could not open or view the images. Rather than assert
visual quality it could not observe, this audit records only **objective,
mechanical pixel metrics** produced by the new tool `tool/ui_screenshot_review.py`.

> **This audit does not certify visual or aesthetic quality.** It cannot confirm
> layout correctness, spacing, alignment, contrast, typography, iconography,
> theming, or the absence of visual defects. Metrics are a triage aid. **A human
> or a vision-capable model must still review every screenshot and sign off.**
> The automated heuristics below are deliberately conservative and produce both
> false negatives and false positives; a "none detected" result is not a pass.

## Method

- Tool: `tool/ui_screenshot_review.py` (Pillow 10.2.0; degrades to a PNG-header
  parser when Pillow is absent).
- Input: `/tmp/opencode/ui-finish-*.png` (15 files).
- Per image it computes:
  - **Dimensions** and pixel count.
  - **Non-blank ratio** — fraction of pixels differing from the dominant
    background color by more than 24/255.
  - **Dominant colors** — top 5 quantized colors with coverage.
  - **Edge density** — fraction of pixels above an edge threshold after a
    `FIND_EDGES` filter (a proxy for visual complexity/detail, not quality).
  - **Content bounding box and margins**, plus a blank heuristic
    (non-blank < 0.5%) and an edge/overflow heuristic (content touching the
    right/bottom or all four image edges).
- Outputs:
  - HTML gallery with linked images + metrics:
    `/tmp/opencode/ui-review/index.html`
  - Machine-readable metrics: `/tmp/opencode/ui-review/metrics.json`
  - Report: `/tmp/opencode/finish-screenshot-review.md`

## Per-screen objective results

| Screen | Dimensions | Non-blank | Edge density | Blank? | Edge/overflow heuristic |
|---|---|---|---|---|---|
| ui-finish-01 | 780×1688 | 20.36% | 3.92% | content present | none detected |
| ui-finish-02 | 720×1280 | 38.64% | 3.89% | content present | content spans all four edges (possible clipping/overflow) |
| ui-finish-03 | 420×1000 | 13.35% | 4.83% | content present | none detected |
| ui-finish-04 | 1024×768 | 9.42% | 4.01% | content present | none detected |
| ui-finish-05 | 1024×768 | 21.49% | 6.52% | content present | none detected |
| ui-finish-06 | 1024×768 | 5.74% | 2.87% | content present | content touches right edge (possible clipping/overflow) |
| ui-finish-07 | 360×640 | 26.84% | 4.91% | content present | content touches right edge (possible clipping/overflow) |
| ui-finish-08 | 1024×768 | 11.45% | 4.00% | content present | none detected |
| ui-finish-09 | 720×1280 | 28.08% | 5.52% | content present | content touches right edge (possible clipping/overflow) |
| ui-finish-10 | 720×1280 | 17.96% | 3.90% | content present | content touches bottom edge (possible clipping/overflow) |
| ui-finish-11 | 360×640 | 27.23% | 5.18% | content present | content touches right edge (possible clipping/overflow) |
| ui-finish-12 | 360×640 | 12.77% | 3.66% | content present | none detected |
| ui-finish-13 | 720×1280 | 31.96% | 3.89% | content present | none detected |
| ui-finish-14 | 1024×768 | 11.74% | 4.86% | content present | none detected |
| ui-finish-15 | 360×640 | 44.06% | 5.11% | content present | content spans all four edges (possible clipping/overflow) |

### Dominant colors (top 2 per screen)

| Screen | Dominant | Second |
|---|---|---|
| ui-finish-01 | #232324 (0.9%) | #151517 (0.7%) |
| ui-finish-02 | #232324 (2.5%) | #0a0a0b (1.0%) |
| ui-finish-03 | #232324 (5.2%) | #151517 (1.8%) |
| ui-finish-04 | #232324 (3.6%) | #151517 (1.3%) |
| ui-finish-05 | #232324 (2.8%) | #151517 (0.9%) |
| ui-finish-06 | #151517 (3.4%) | #232324 (1.6%) |
| ui-finish-07 | #232324 (9.0%) | #151517 (4.6%) |
| ui-finish-08 | #151517 (3.0%) | #232324 (2.1%) |
| ui-finish-09 | #232324 (3.0%) | #f9fafb (0.2%) |
| ui-finish-10 | #151517 (2.3%) | #232324 (1.5%) |
| ui-finish-11 | #232324 (14.8%) | #f9fafb (2.0%) |
| ui-finish-12 | #232324 (10.2%) | #151517 (4.9%) |
| ui-finish-13 | #232324 (3.0%) | #ffffff (0.8%) |
| ui-finish-14 | #232324 (3.0%) | #151517 (2.0%) |
| ui-finish-15 | #232324 (11.1%) | #f9fafb (3.5%) |

Dominant-color ratios are measured on a 240×240 downscale, so percentages are
relative to that sample, not the full frame.

## What the metrics do and do not show

**Supported by the numbers**

- All 15 files are valid, non-blank PNGs with real rendered content
  (non-blank coverage 5.74%–44.06%; none near the blank threshold).
- They are consistent dark-themed screens (dominant `#232324`/`#151517` with
  light text `#f9fafb`/`#ffffff`), across three viewport classes:
  360×640 phone, 720×1280 / 780×1688 tall mobile, and 1024×768 desktop/tablet.
- Detail is present on every screen (edge density 2.87%–6.52%).

**Not shown (and cannot be concluded)**

- Whether layouts are correct, aligned, or unclipped.
- Whether text is legible, wrapping correctly, or overflowing.
- Contrast ratios, touch-target sizes, safe-area compliance.
- Color correctness, theming consistency, icon quality.
- Whether any screen "looks finished" or good.

## Edge/overflow heuristic caveat

Seven screens flag the edge heuristic (02, 06, 07, 09, 10, 11, 15). This is
**not** evidence of a defect. Full-bleed backgrounds, gradients, system bars,
scrollbars, and edge-to-edge imagery all cause the content bounding box to
touch an image border. The heuristic exists only to direct a reviewer's
attention; each flag must be confirmed or dismissed by eye. Conversely, a
"none detected" result does not rule out clipping or overflow.

## Reviewer handoff (required)

1. Open `/tmp/opencode/ui-review/index.html` — each screenshot is shown beside
   its metrics.
2. A human or vision-capable model must visually confirm, per screen: layout and
   spacing, alignment, text legibility/wrapping, contrast, touch targets,
   theming, and the flagged edge/overflow items.
3. Record an explicit per-screen sign-off. **This audit is not that sign-off.**
