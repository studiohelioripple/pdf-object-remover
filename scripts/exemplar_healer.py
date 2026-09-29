#!/usr/bin/env python3
"""
Exemplar Background Transfer & Perimeter Seam Healing for PDF Slide Pages
Part of the pdf-object-remover skill on macOS.
-------------------------------------------------------------------------
Enables seamless object removal over structured, patterned, or textured PDF slides
(e.g., architectural drafting grids, engineering schematics, hatched paper):
1. Detects or discovers the 'should-be-background':
   - Phase-aligned donor patch from adjacent clean areas via 2D cross-correlation.
   - Or neural background synthesis via Big-LaMa (Fast Fourier Convolutions) on Apple Silicon GPU (`mps`).
2. Slices and blends the reconstructed piece onto the target zone.
3. Performs border seam healing using Euclidean distance-transform guided feathering.
"""

from __future__ import annotations

import argparse
import os
import sys
import subprocess
from pathlib import Path
from typing import Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent

# Check for GNN venv with torch, torchvision, simple_lama_inpainting
GNN_VENV_PYTHON = Path.home() / "Projects/GNN/.venv/bin/python3"
KEYNOTE_VENV_PYTHON = Path.home() / ".gemini/config/skills/keynote-tools/venv/bin/python3"


def ensure_environment() -> None:
    needed_modules = ["torch", "simple_lama_inpainting"]
    missing = []
    for mod in needed_modules:
        try:
            __import__(mod)
        except ImportError:
            missing.append(mod)

    if missing:
        # Re-execute under existing venv if available
        if GNN_VENV_PYTHON.exists() and sys.executable != str(GNN_VENV_PYTHON.resolve()):
            cmd = [str(GNN_VENV_PYTHON)] + sys.argv
            os.execv(str(GNN_VENV_PYTHON), cmd)
        elif KEYNOTE_VENV_PYTHON.exists() and sys.executable != str(KEYNOTE_VENV_PYTHON.resolve()):
            cmd = [str(KEYNOTE_VENV_PYTHON)] + sys.argv
            os.execv(str(KEYNOTE_VENV_PYTHON), cmd)

ensure_environment()

import cv2
import numpy as np
from PIL import Image

try:
    import torch
    from simple_lama_inpainting import SimpleLama
    HAS_LAMA = True
except ImportError:
    HAS_LAMA = False


# ------------------------------------------------------------------------------
# Phase-Aligned Donor Patch Discovery (for repetitive grids/hatches)
# ------------------------------------------------------------------------------

def find_phase_aligned_donor(
    image: np.ndarray,
    target_box: Tuple[int, int, int, int],
    search_direction: str = "left"
) -> Tuple[np.ndarray, Tuple[int, int]]:
    """
    Finds an adjacent unoccluded donor patch matching periodic background textures
    (e.g., architectural drafting grids or repetitive patterns) using 2D cross-correlation.
    """
    bx, by, bw, bh = target_box
    img_h, img_w = image.shape[:2]

    if search_direction == "left":
        cand_x1 = max(0, bx - bw * 3)
        cand_x2 = max(0, bx - 10)
        cand_y1 = max(0, by - 20)
        cand_y2 = min(img_h, by + bh + 20)
    else:
        cand_x1 = max(0, bx - 20)
        cand_x2 = min(img_w, bx + bw + 20)
        cand_y1 = max(0, by - bh * 3)
        cand_y2 = max(0, by - 10)

    if (cand_x2 - cand_x1) < bw or (cand_y2 - cand_y1) < bh:
        donor_x = max(0, bx - bw - 10)
        donor_y = by
        donor_patch = image[donor_y : donor_y + bh, donor_x : donor_x + bw]
        return donor_patch, (donor_x, donor_y)

    search_region = image[cand_y1:cand_y2, cand_x1:cand_x2]
    strip_w = min(15, bw // 2)
    sample_strip = image[by : by + bh, max(0, bx - strip_w) : bx]

    if sample_strip.shape[1] > 0 and search_region.shape[0] >= bh and search_region.shape[1] >= bw:
        res = cv2.matchTemplate(
            cv2.cvtColor(search_region, cv2.COLOR_BGR2GRAY),
            cv2.cvtColor(sample_strip, cv2.COLOR_BGR2GRAY),
            cv2.TM_CCOEFF_NORMED
        )
        _, _, _, max_loc = cv2.minMaxLoc(res)
        best_x = cand_x1 + max_loc[0]
        best_y = cand_y1 + max_loc[1]
        donor_x = max(0, min(img_w - bw, best_x))
        donor_y = max(0, min(img_h - bh, best_y))
    else:
        donor_x = max(0, bx - bw - 15)
        donor_y = by

    donor_patch = image[donor_y : donor_y + bh, donor_x : donor_x + bw]
    return donor_patch, (donor_x, donor_y)


# ------------------------------------------------------------------------------
# Perimeter Border Seam Healing (Distance Transform Guided Ramp)
# ------------------------------------------------------------------------------

def heal_borders_and_seams(
    base_image: np.ndarray,
    merged_image: np.ndarray,
    target_box: Tuple[int, int, int, int],
    seam_width: int = 6
) -> np.ndarray:
    """
    Blends exclusively along the outer perimeter seams between the base image
    and the stamped replacement piece using distance transform guided gradient feathering.
    """
    bx, by, bw, bh = target_box
    h, w = base_image.shape[:2]

    box_mask = np.zeros((h, w), dtype=np.float32)
    box_mask[by : by + bh, bx : bx + bw] = 1.0

    dist_inside = cv2.distanceTransform((box_mask * 255).astype(np.uint8), cv2.DIST_L2, 5)
    weight_map = np.clip(dist_inside / max(1.0, float(seam_width)), 0.0, 1.0)
    weight_map = cv2.GaussianBlur(weight_map, (seam_width * 2 + 1, seam_width * 2 + 1), 0)
    weight_map = weight_map[:, :, np.newaxis]

    blended = (base_image.astype(np.float32) * (1.0 - weight_map) +
               merged_image.astype(np.float32) * weight_map)
    return np.clip(blended, 0, 255).astype(np.uint8)


# ------------------------------------------------------------------------------
# Neural Fast Fourier Inpainting (Big-LaMa on Apple Silicon GPU)
# ------------------------------------------------------------------------------

_LAMA_INSTANCE = None

def get_lama_model() -> Optional[SimpleLama]:
    global _LAMA_INSTANCE
    if not HAS_LAMA:
        return None
    if _LAMA_INSTANCE is None:
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        try:
            _LAMA_INSTANCE = SimpleLama(device=device)
        except Exception as e:
            fputs = sys.stderr.write
            fputs(f"Notice: Big-LaMa GPU init fallback: {e}\n")
            _LAMA_INSTANCE = SimpleLama(device="cpu")
    return _LAMA_INSTANCE


def inpaint_with_lama(
    image: Image.Image,
    mask: Image.Image,
    target_box: Optional[Tuple[int, int, int, int]] = None
) -> Image.Image:
    lama = get_lama_model()
    if lama is None:
        # Fallback to OpenCV Telea inpainting if PyTorch/LaMa unavailable
        img_np = np.array(image.convert("RGB"))
        mask_np = np.array(mask.convert("L"))
        inpainted_bgr = cv2.inpaint(cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR), mask_np, 3, cv2.INPAINT_TELEA)
        return Image.fromarray(cv2.cvtColor(inpainted_bgr, cv2.COLOR_BGR2RGB))

    if target_box is None:
        return lama(image, mask)

    bx, by, bw, bh = target_box
    img_w, img_h = image.size

    pad_x = 150
    pad_y = 100
    x0 = max(0, bx - pad_x)
    y0 = max(0, by - pad_y)
    x1 = min(img_w, bx + bw + pad_x)
    y1 = min(img_h, by + bh + pad_y)

    patch_img = image.crop((x0, y0, x1, y1))
    patch_mask = mask.crop((x0, y0, x1, y1))

    inpainted_patch = lama(patch_img, patch_mask)

    final_img = image.copy()
    final_img.paste(inpainted_patch, (x0, y0))
    return final_img


# ------------------------------------------------------------------------------
# Core Unified Image Healer
# ------------------------------------------------------------------------------

def heal_image_array(
    img_bgr: np.ndarray,
    box: Tuple[int, int, int, int],
    strategy: str = "composite",
    seam_width: int = 6
) -> np.ndarray:
    h, w = img_bgr.shape[:2]
    bx, by, bw, bh = box
    bx = max(0, min(w - 1, bx))
    by = max(0, min(h - 1, by))
    bw = max(1, min(w - bx, bw))
    bh = max(1, min(h - by, bh))
    clamped_box = (bx, by, bw, bh)

    if strategy in ["exemplar", "copy", "clone"]:
        donor_patch, _ = find_phase_aligned_donor(img_bgr, clamped_box)
        merged = img_bgr.copy()
        merged[by : by + bh, bx : bx + bw] = donor_patch[:bh, :bw]
        return heal_borders_and_seams(img_bgr, merged, clamped_box, seam_width=seam_width)

    elif strategy in ["lama", "neural"]:
        pil_img = Image.fromarray(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))
        mask_np = np.zeros((h, w), dtype=np.uint8)
        mask_np[by : by + bh, bx : bx + bw] = 255
        pil_mask = Image.fromarray(mask_np)

        result_pil = inpaint_with_lama(pil_img, pil_mask, clamped_box)
        return cv2.cvtColor(np.array(result_pil), cv2.COLOR_RGB2BGR)

    else:  # Composite strategy (Neural / Exemplar + Border Seam Healing)
        pil_img = Image.fromarray(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))
        mask_np = np.zeros((h, w), dtype=np.uint8)
        mask_np[by : by + bh, bx : bx + bw] = 255
        pil_mask = Image.fromarray(mask_np)

        inpaint_pil = inpaint_with_lama(pil_img, pil_mask, clamped_box)
        inpaint_bgr = cv2.cvtColor(np.array(inpaint_pil), cv2.COLOR_RGB2BGR)

        return heal_borders_and_seams(img_bgr, inpaint_bgr, clamped_box, seam_width=seam_width)


def main():
    parser = argparse.ArgumentParser(description="Exemplar & Neural Seam Healer for Slide Images")
    parser.add_argument("--input", "-i", required=True)
    parser.add_argument("--output", "-o", required=True)
    parser.add_argument("--box", "-b", required=True, help="Target box 'x,y,w,h'")
    parser.add_argument("--strategy", "-s", default="composite", choices=["composite", "exemplar", "lama"])
    parser.add_argument("--seam-width", type=int, default=6)
    args = parser.parse_args()

    parts = [int(p.strip()) for p in args.box.split(",")]
    if len(parts) != 4:
        raise ValueError("Invalid --box format. Expected 'x,y,w,h'")

    img = cv2.imread(args.input)
    if img is None:
        raise FileNotFoundError(f"Cannot read image at {args.input}")

    healed = heal_image_array(img, (parts[0], parts[1], parts[2], parts[3]), strategy=args.strategy, seam_width=args.seam_width)
    cv2.imwrite(args.output, healed)
    print(f"[✓] Saved healed image to {args.output}")


if __name__ == "__main__":
    main()
