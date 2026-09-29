---
name: pdf-object-remover
description: >-
  Detect and remove recurring watermarks, badges, logos, timestamps, stamps, and labels from multi-page PDF documents and slide decks on macOS.
  Identifies the target object on a single anchor page (via Apple Vision OCR, spatial zones, or bounding boxes), normalizes the coordinates,
  and applies page-adaptive healing (2D gradient surface detrending, grain noise synthesis, exemplar grid phase-matching, and Big-LaMa neural inpainting)
  across all pages at that matching position.
---

# PDF-Object-Remover (`pdf-object-remover`)

Unified macOS document and presentation healing suite for **Multi-Page PDF Documents** and **Slide Decks**.

Addresses a fundamental invariant in presentation and document cleaning:
> **A watermark, badge, counter, stamp, or label recurs at the identical relative position across many slides, but the underlying background texture, gradient angle, paper tone, or grid pattern varies significantly from page to page.**

Following the architecture of `keynote-tools`, `pdf-object-remover` detects and addresses the target object on a single **Anchor Page** (via Apple Vision OCR text matching, spatial quadrants, or explicit boxes), normalizes the bounding area, and **heals all slides/pages at that matching position**, adapting page-by-page to each slide's individual background color, 2D gradient, grain noise, or drafting grid.

---

## 1. Capabilities & Core Features

- **Anchor Page Detection**: Inspects any specified reference page (e.g. Page 1) to identify target text (`--filter "CONFIDENTIAL"` / `--query "Draft"`), spatial zone (`--zone bottom-right`, `footer`, `header`, `logo`), or explicit bounds (`--box x,y,w,h`).
- **Normalized Relative Coordinates**: Extracts normalized floating-point coordinates `(normX, normY, normW, normH)` so the target area scales precisely across pages of varying dimensions or orientations (portrait vs. landscape).
- **Slide-Adaptive In-Place Healing**:
  - **`gradient`**: Samples the perimeter 14px ring on that specific page, fits 2D least-squares planar equations ($R, G, B = ax + by + c$), calculates residual variance (MAD) for high-frequency noise/grain synthesis, and blends with edge feathering.
  - **`solid`**: Dominant median perimeter border color fill for flat backgrounds.
  - **`auto`**: Smart automatic classification (gradient vs solid) per slide.
  - **`exemplar`**: Phase-aligned 2D cross-correlation donor patch transfer for architectural drafting grids, blueprint lines, and repeating patterns.
  - **`lama` / `composite`**: Big-LaMa neural inpainting running on Apple Silicon GPU (`mps`) with distance-transform guided perimeter feathering ($6\text{ px}$ band).
- **Diagnostic Preview Mask**: `--preview-mask mask.png` saves a high-res image of the anchor page with the detected bounding box highlighted in semi-transparent red and green borders for visual verification before processing.
- **Native Apple Silicon Speed**: Built with Swift, `PDFKit`, `CoreGraphics`, `Vision`, and `CoreImage` for sub-second vector rendering and reconstruction.

---

## 2. Installed CLI Tools & Shortcuts

Installed in `~/.local/bin` and `~/bin`:
- **`pdf-object-remover`**: Primary Python & Swift orchestrator.
- **`pdf-remover`**: Fast alias for `pdf-object-remover`.
- **`pdf-healer`**: Native compiled Apple Silicon executable for ultra-fast direct execution.

---

## 3. Quick Start & Practical Recipes

### Recipe 1: Inspect & Verify Detection (Dry-Run Preview)
Inspect Anchor Page 1, detect the target watermark text via Apple Vision OCR, output coordinates, and write a diagnostic preview mask to disk:
```bash
pdf-object-remover \
  --input presentation.pdf \
  --anchor-page 1 \
  --filter "CONFIDENTIAL" \
  --preview-mask preview_mask.png \
  --inspect
```

### Recipe 2: Heal All Pages via Auto-Adaptive Mode
Detects the target badge on Page 1, normalizes its coordinates, and heals all pages across the PDF, automatically matching each page's unique color or gradient:
```bash
pdf-object-remover \
  --input presentation.pdf \
  --output presentation_clean.pdf \
  --anchor-page 1 \
  --filter "CONFIDENTIAL DRAFT" \
  --padding 6 \
  --mode auto
```

### Recipe 3: Remove Bottom-Right Corner Logo & Extend Flush to Edge
Removes a corner stamp or logo and extends flush to the right/bottom page boundaries to guarantee no thin hairline remnants:
```bash
pdf-object-remover \
  --input document.pdf \
  --output document_clean.pdf \
  --anchor-page 1 \
  --zone bottom-right-corner \
  --extend-right \
  --extend-bottom \
  --feather 5
```

### Recipe 4: Erase Recurring Header or Footer Disclaimer Bar
Removes a persistent header or footer bar across all slides:
```bash
pdf-object-remover \
  --input deck.pdf \
  --output deck_clean.pdf \
  --anchor-page 1 \
  --zone footer \
  --mode gradient
```

### Recipe 5: Architectural Drafting Paper / Grid Slides (`exemplar`)
For blueprint sets, structural drawings, or grid slides where removing a stamp requires preserving repeating grid lines:
```bash
pdf-object-remover \
  --input blueprints.pdf \
  --output blueprints_clean.pdf \
  --anchor-page 1 \
  --filter "NOT FOR CONSTRUCTION" \
  --mode exemplar \
  --feather 6
```

### Recipe 6: Selective Page Range Processing
Heal only slides 2 through 15, leaving the title slide untouched:
```bash
pdf-object-remover \
  --input deck.pdf \
  --output deck_clean.pdf \
  --anchor-page 2 \
  --filter "INTERNAL ONLY" \
  --pages "2-15"
```

---

## 4. CLI Flag Reference

| Flag | Shortcut | Default | Description |
|---|---|---|---|
| `--input` | `-i` | *Required* | Path to input PDF document |
| `--output` | `-o` | *Required* (unless `--inspect`) | Path to output cleaned PDF document |
| `--anchor-page` | `-p` | `1` | Reference page (1-based) to detect target object on |
| `--filter` / `--query` | `-f` / `-q` | `None` | Case-insensitive OCR text query/substring to detect |
| `--zone` | `-z` | `bottom-right` | Spatial zone: `bottom-right`, `bottom-right-corner`, `logo`, `bottom-left`, `top-right`, `top-left`, `footer`, `header`, `all`, `custom` |
| `--box` | `-b` | `None` | Explicit bounding box: `"x,y,w,h"` (normalized 0..1 or pixel coords) |
| `--mode` | `-m` | `auto` | Healing mode: `auto`, `gradient`, `solid`, `exemplar`, `lama`, `composite` |
| `--dpi` | | `300.0` | PDF page rendering resolution DPI |
| `--pages` | | `all` | Target pages to heal (`all`, `1-10`, `2,4,6`) |
| `--exclude-pages`| | `""` | Pages to exempt from healing |
| `--padding` | | `4` | Pixel padding around detected object bounds |
| `--feather` | | `4` | Perimeter edge feathering ramp width in pixels |
| `--extend-right`| | `false` | Extend mask box flush to right page boundary |
| `--extend-bottom`| | `false` | Extend mask box flush to bottom page boundary |
| `--preview-mask`| | `None` | Path to save diagnostic highlighted preview image |
| `--inspect` | | `false` | Inspect anchor page and print coordinates without modifying PDF |
| `--json` | | `false` | Output results/stats in structured JSON format |

---

## 5. Technical Architecture & Invariants

1. **Two-Phase Architecture**:
   - **Phase 1 (Anchor Detection)**: Runs Apple Vision OCR (`VNRecognizeTextRequest`) or zone filtering strictly on the anchor page to extract normalized coordinates $\left(\frac{x}{W}, \frac{y}{H}, \frac{w}{W}, \frac{h}{H}\right)$.
   - **Phase 2 (Cross-Page Propagation)**: Applies the normalized bounding area across all target pages, executing independent local background detrending and healing per slide.
2. **2D Surface Detrending**:
   - Least-squares planar fit: $V(x, y) = a_v x + b_v y + c_v$ for $V \in \{R, G, B\}$.
   - Residual variance MAD noise estimation prevents flat, plastic patch appearance.
3. **Seam-Free Feathering**:
   - Gaussian ramp guided by distance transforms ensures zero harsh edges between original and healed pixels.
4. **Resolution Independence**:
   - Renders at 300 DPI for high print and presentation fidelity while retaining original PDF media box point sizes.
