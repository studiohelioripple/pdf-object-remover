#!/bin/bash
# ==============================================================================
# PDF-Object-Remover: Sample Workflows & Practical Recipes
# ==============================================================================

INPUT_PDF="sample_deck.pdf"
OUTPUT_PDF="sample_deck_cleaned.pdf"

# ------------------------------------------------------------------------------
# 1. Non-Destructive Inspection & Visual Mask Verification
# ------------------------------------------------------------------------------
# Inspects Anchor Page 1, detects the "CONFIDENTIAL" watermark, outputs bounding
# coordinates, and writes a diagnostic red-highlighted preview mask to disk.
pdf-object-remover \
  --input "$INPUT_PDF" \
  --anchor-page 1 \
  --filter "CONFIDENTIAL" \
  --preview-mask "anchor_mask_preview.png" \
  --inspect

# ------------------------------------------------------------------------------
# 2. Basic Cross-Slide Watermark Erase (Auto-Healing)
# ------------------------------------------------------------------------------
# Detects "DRAFT" in the bottom-right corner of Page 1, applies the bounding box
# across all 50 slides, adapting to each slide's unique color/gradient.
pdf-object-remover \
  --input "$INPUT_PDF" \
  --output "$OUTPUT_PDF" \
  --anchor-page 1 \
  --filter "DRAFT" \
  --zone bottom-right \
  --padding 6 \
  --mode auto

# ------------------------------------------------------------------------------
# 3. Corner Brand Logo / Stamp Removal (Flush to Canvas Edge)
# ------------------------------------------------------------------------------
# Removes a corner logo and extends flush to the right boundary so no thin line remains:
pdf-object-remover \
  --input "$INPUT_PDF" \
  --output "$OUTPUT_PDF" \
  --anchor-page 1 \
  --zone bottom-right-corner \
  --extend-right \
  --padding 4 \
  --feather 5

# ------------------------------------------------------------------------------
# 4. Header or Footer Notice Bar Erase
# ------------------------------------------------------------------------------
# Erases a full-width footer disclaimer across all pages:
pdf-object-remover \
  --input "$INPUT_PDF" \
  --output "$OUTPUT_PDF" \
  --anchor-page 1 \
  --zone footer \
  --mode gradient

# ------------------------------------------------------------------------------
# 5. Architectural Blueprint / Grid Slide Healing (Exemplar Mode)
# ------------------------------------------------------------------------------
# Uses 2D normalized cross-correlation to find phase-matched grid donor patches:
pdf-object-remover \
  --input "blueprint_set.pdf" \
  --output "blueprint_set_clean.pdf" \
  --anchor-page 1 \
  --filter "PRELIMINARY" \
  --mode exemplar \
  --feather 6

# ------------------------------------------------------------------------------
# 6. High-Fidelity Big-LaMa Neural Synthesis on Apple Silicon GPU
# ------------------------------------------------------------------------------
# For textured presentation slides or illustrated backgrounds:
pdf-object-remover \
  --input "illustrated_presentation.pdf" \
  --output "illustrated_presentation_clean.pdf" \
  --anchor-page 2 \
  --zone top-right \
  --mode composite \
  --dpi 300
