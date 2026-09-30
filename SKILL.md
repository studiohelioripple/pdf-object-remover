---
name: pdf-object-remover
description: >-
  Detect and remove recurring watermarks, badges, logos, timestamps, stamps, and labels from multi-page PDF documents and slide decks on macOS.
  Identifies the target object on a single anchor page (via Apple Vision OCR, spatial zones, or Preview.app interactive markup boxes), normalizes the coordinates,
  and applies page-adaptive healing (2D gradient surface detrending, grain noise synthesis, exemplar grid phase-matching, and Big-LaMa neural inpainting)
  across all pages or targeted individual pages.
---

# PDF-Object-Remover (`pdf-object-remover`)

Unified macOS document and presentation healing suite for **Multi-Page PDF Documents** and **Slide Decks** with full **macOS Preview.app Visual Interactivity**.

Addresses a fundamental invariant in presentation and document cleaning:
> **A watermark, badge, counter, stamp, or label recurs at the identical relative position across many slides, but the underlying background texture, gradient angle, paper tone, or grid pattern varies significantly from page to page.**

Following the architecture of `keynote-tools`, `pdf-object-remover` detects and addresses the target object on a single **Anchor Page** (via Apple Vision OCR text matching, spatial quadrants, explicit boxes, or interactive Preview.app markup shapes), normalizes the bounding area, and **heals all slides/pages (or selected single pages) at that matching position**, adapting page-by-page to each slide's individual background color, 2D gradient, grain noise, or drafting grid.

---

## 1. Capabilities & Core Features

- **Anchor Page Detection**: Inspects any specified reference page (e.g. Page 1) to identify target text (`--filter "CONFIDENTIAL"` / `--query "Draft"`), spatial zone (`--zone bottom-right`, `footer`, `header`, `logo`), or explicit bounds (`--box x,y,w,h`).
- **Interactive macOS Preview.app Integration (`--open-preview` / `-P` / `--interactive` / `-I`)**:
  - Automatically inserts an editable native PDF rectangle annotation (`PDFAnnotationSubtypeSquare`) over the detected spot and opens the staged document directly in **Preview.app**.
  - Allows you to move, resize, or draw your own shapes (rectangles, highlights, circles, redaction boxes) in Preview.app using its native Markup Toolbar (`Cmd+Shift+A`).
  - Detects the updated/drawn masking object directly from Preview.app (`--from-annotation`) upon saving (`Cmd+S`).
- **Configurable Scope (`--scope all` vs `--scope single` / `--scope page`)**:
  - **All Pages (`--scope all`, Default)**: Normalizes the mask coordinates relative to page dimensions and heals all pages across the document at that matching position, adapting page-by-page.
  - **Single Page (`--scope single` / `--scope page`)**: Heals strictly the anchor page where the mask was addressed, leaving other pages untouched.
  - **Custom Range (`--pages "1-5,8"`)**: Selective subset healing.
- **Normalized Relative Coordinates**: Extracts normalized floating-point coordinates `(normX, normY, normW, normH)` so the target area scales precisely across pages of varying dimensions or orientations (portrait vs. landscape).
- **Slide-Adaptive In-Place Healing**:
  - **`gradient`**: Samples the perimeter 14px ring on that specific page, fits 2D least-squares planar equations ($R, G, B = ax + by + c$), calculates residual variance (MAD) for high-frequency noise/grain synthesis, and blends with edge feathering.
  - **`solid`**: Dominant median perimeter border color fill for flat backgrounds.
  - **`auto`**: Smart automatic classification (gradient vs solid) per slide.
  - **`exemplar`**: Phase-aligned 2D cross-correlation donor patch transfer for architectural drafting grids, blueprint lines, and repeating patterns.
  - **`lama` / `composite`**: Big-LaMa neural inpainting running on Apple Silicon GPU (`mps`) with distance-transform guided perimeter feathering ($6\text{ px}$ band).
- **Zero-Leftover Annotation Stripping**: Automatically strips temporary markup boxes and staging annotations before writing the final output PDF.
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

### Recipe 1: Visual Interactive Masking with Preview.app
Opens the document in Preview.app with the target area highlighted by a red rectangle. Adjust the rectangle handles in Preview.app, press `Cmd+S`, and hit Enter in the terminal to heal all pages:
```bash
pdf-object-remover \
  --input presentation.pdf \
  --output presentation_clean.pdf \
  --anchor-page 1 \
  --filter "CONFIDENTIAL" \
  --open-preview
```

### Recipe 2: Interactive Prompt Workflow
Asks interactively if you'd like to open Preview.app, and prompts you to choose between healing all pages or only the current page:
```bash
pdf-object-remover \
  --input deck.pdf \
  --output deck_clean.pdf \
  --interactive
```

### Recipe 3: Heal Only That Specific Page (`--scope single`)
Detect or address an object on Page 2 and heal **only Page 2**, leaving the rest of the document intact:
```bash
pdf-object-remover \
  --input blueprints.pdf \
  --output blueprints_clean.pdf \
  --anchor-page 2 \
  --from-annotation \
  --scope single
```

### Recipe 4: Stage Preview PDF Only (for external inspection)
Generates an annotated staging PDF with the target rectangle inserted on Page 1 without performing healing:
```bash
pdf-object-remover \
  --input document.pdf \
  --anchor-page 1 \
  --zone bottom-right-corner \
  --stage-preview document_staged.pdf
```

### Recipe 5: Heal All Pages via Auto-Adaptive Mode (Non-interactive)
Detects the target badge on Page 1, normalizes its coordinates, and heals all pages across the PDF:
```bash
pdf-object-remover \
  --input presentation.pdf \
  --output presentation_clean.pdf \
  --anchor-page 1 \
  --filter "CONFIDENTIAL DRAFT" \
  --padding 6 \
  --mode auto
```

### Recipe 6: Remove Bottom-Right Corner Logo & Extend Flush to Edge
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

### Recipe 7: Architectural Drafting Paper / Grid Slides (`exemplar`)
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

---

## 4. CLI Flag Reference

| Flag | Shortcut | Default | Description |
|---|---|---|---|
| `--input` | `-i` | *Required* | Path to input PDF document |
| `--output` | `-o` | *Required* (unless `--inspect` or `--stage-preview`) | Path to output cleaned PDF document |
| `--anchor-page` | `-p` | `1` | Reference page (1-based) to detect target object on |
| `--open-preview` / `--preview-app` | `-P` | `false` | Stage rectangle annotation and open in **Preview.app** for visual adjustment |
| `--interactive` | `-I` | `false` | Interactively prompt whether to open in Preview.app and confirm scope |
| `--from-annotation` / `--detect-annotation` | | `false` | Extract target mask bounds directly from Preview.app markup annotation |
| `--scope` | | `all` | Healing scope: `all` (all pages), `single` / `page` (anchor page only), `ask` |
| `--stage-preview` | | `None` | Path to save staged PDF with target rectangle annotation and exit |
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

1. **Preview.app Native Markup Pipeline**:
   - Staging generates native `PDFAnnotationSubtypeSquare` objects placed on the target page.
   - User edits in Preview.app update Quartz PDF coordinates.
   - The engine converts PDFKit bottom-left point bounds to normalized $(0.0\dots 1.0)$ top-left coordinates:
     $$\text{normX} = \frac{\text{bounds.origin.x} - \text{mediaBox.origin.x}}{\text{mediaBox.width}}$$
     $$\text{normY} = \frac{\text{mediaBox.height} - (\text{bounds.origin.y} - \text{mediaBox.origin.y} + \text{bounds.height})}{\text{mediaBox.height}}$$
   - All annotations are stripped before writing the final output PDF.
2. **Two-Phase Architecture**:
   - **Phase 1 (Anchor Detection)**: Runs Apple Vision OCR (`VNRecognizeTextRequest`), zone filtering, or Preview.app annotation extraction on the anchor page.
   - **Phase 2 (Propagation / Scoping)**: Applies the normalized bounding area across all target pages (or strictly the single anchor page), executing independent local background detrending and healing per slide.
3. **2D Surface Detrending**:
   - Least-squares planar fit: $V(x, y) = a_v x + b_v y + c_v$ for $V \in \{R, G, B\}$.
   - Residual variance MAD noise estimation prevents flat, plastic patch appearance.
4. **Seam-Free Feathering**:
   - Gaussian ramp guided by distance transforms ensures zero harsh edges between original and healed pixels.
5. **Resolution Independence**:
   - Renders at 300 DPI for high print and presentation fidelity while retaining original PDF media box point sizes.
