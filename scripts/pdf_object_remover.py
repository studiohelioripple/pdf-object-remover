#!/usr/bin/env python3
"""
PDF-Object-Remover: Master CLI & Cross-Page Healing Suite
Part of the pdf-object-remover skill on macOS.
-------------------------------------------------------------------------------
1. Identifies and addresses a target object on an Anchor Page:
   - Via Apple Vision OCR text query (--filter "CONFIDENTIAL")
   - Via spatial quadrant / zone (--zone bottom-right, footer, header, logo)
   - Or via explicit coordinates (--box "x,y,w,h")
2. Normalizes the target bounding box relative to page bounds.
3. Automatically propagates that exact position across ALL slides/pages.
4. Executes page-adaptive healing on every page individually (matching each
   page's unique 2D gradient, grain noise, solid fill, or architectural grid).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
NATIVE_HEALER_BIN = SCRIPT_DIR / "pdf_healer"
BUILD_SCRIPT = SCRIPT_DIR / "build.sh"
EXEMPLAR_SCRIPT = SCRIPT_DIR / "exemplar_healer.py"



def ensure_native_binary() -> Path:
    """Ensure the native Swift binary exists, compiling it if necessary."""
    if not NATIVE_HEALER_BIN.exists() or not os.access(NATIVE_HEALER_BIN, os.X_OK):
        print(f"🔨 Compiling native Swift PDF healer engine at {BUILD_SCRIPT}...")
        res = subprocess.run(["/bin/bash", str(BUILD_SCRIPT)], capture_output=True, text=True)
        if res.returncode != 0:
            print(f"Error compiling native healer:\n{res.stderr}", file=sys.stderr)
            sys.exit(1)
    return NATIVE_HEALER_BIN


def inspect_anchor_page(
    input_pdf: str,
    anchor_page: int = 1,
    zone: str = "bottom-right",
    text_filter: Optional[str] = None,
    explicit_box: Optional[str] = None,
    preview_mask_path: Optional[str] = None,
    dpi: float = 300.0,
    padding: int = 4,
    extend_right: bool = False,
    extend_bottom: bool = False,
    min_x: Optional[float] = None,
    max_x: Optional[float] = None,
    min_y: Optional[float] = None,
    max_y: Optional[float] = None,
) -> Dict[str, Any]:
    """Inspects the anchor page and returns detected object coordinates and metadata."""
    healer_bin = ensure_native_binary()

    cmd = [
        str(healer_bin),
        "--input", os.path.abspath(input_pdf),
        "--anchor-page", str(anchor_page),
        "--zone", zone,
        "--dpi", str(dpi),
        "--padding", str(padding),
        "--inspect",
        "--json",
    ]

    if text_filter:
        cmd.extend(["--filter", text_filter])
    if explicit_box:
        cmd.extend(["--box", explicit_box])
    if preview_mask_path:
        cmd.extend(["--preview-mask", os.path.abspath(preview_mask_path)])
    if extend_right:
        cmd.append("--extend-right")
    if extend_bottom:
        cmd.append("--extend-bottom")
    if min_x is not None:
        cmd.extend(["--min-x", str(min_x)])
    if max_x is not None:
        cmd.extend(["--max-x", str(max_x)])
    if min_y is not None:
        cmd.extend(["--min-y", str(min_y)])
    if max_y is not None:
        cmd.extend(["--max-y", str(max_y)])

    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Native healer inspection error:\n{res.stderr.strip()}")

    try:
        return json.loads(res.stdout.strip())
    except json.JSONDecodeError:
        return {"raw_output": res.stdout.strip()}


def process_with_native_engine(
    input_pdf: str,
    output_pdf: str,
    anchor_page: int = 1,
    zone: str = "bottom-right",
    text_filter: Optional[str] = None,
    explicit_box: Optional[str] = None,
    mode: str = "auto",
    dpi: float = 300.0,
    pages: str = "all",
    exclude_pages: str = "",
    padding: int = 4,
    feather: int = 4,
    extend_right: bool = False,
    extend_bottom: bool = False,
    preview_mask_path: Optional[str] = None,
    min_x: Optional[float] = None,
    max_x: Optional[float] = None,
    min_y: Optional[float] = None,
    max_y: Optional[float] = None,
    json_output: bool = False,
) -> bool:
    """Dispatches to the native Swift engine for high-speed multi-page processing."""
    healer_bin = ensure_native_binary()

    cmd = [
        str(healer_bin),
        "--input", os.path.abspath(input_pdf),
        "--output", os.path.abspath(output_pdf),
        "--anchor-page", str(anchor_page),
        "--zone", zone,
        "--mode", mode,
        "--dpi", str(dpi),
        "--pages", pages,
        "--padding", str(padding),
        "--feather", str(feather),
    ]

    if text_filter:
        cmd.extend(["--filter", text_filter])
    if explicit_box:
        cmd.extend(["--box", explicit_box])
    if exclude_pages:
        cmd.extend(["--exclude-pages", exclude_pages])
    if extend_right:
        cmd.append("--extend-right")
    if extend_bottom:
        cmd.append("--extend-bottom")
    if preview_mask_path:
        cmd.extend(["--preview-mask", os.path.abspath(preview_mask_path)])
    if min_x is not None:
        cmd.extend(["--min-x", str(min_x)])
    if max_x is not None:
        cmd.extend(["--max-x", str(max_x)])
    if min_y is not None:
        cmd.extend(["--min-y", str(min_y)])
    if max_y is not None:
        cmd.extend(["--max-y", str(max_y)])
    if json_output:
        cmd.append("--json")

    res = subprocess.run(cmd)
    return res.returncode == 0


def process_with_exemplar_engine(
    input_pdf: str,
    output_pdf: str,
    anchor_page: int = 1,
    zone: str = "bottom-right",
    text_filter: Optional[str] = None,
    explicit_box: Optional[str] = None,
    strategy: str = "composite",
    dpi: float = 300.0,
    pages: str = "all",
    exclude_pages: str = "",
    padding: int = 4,
    seam_width: int = 6,
    extend_right: bool = False,
    extend_bottom: bool = False,
    preview_mask_path: Optional[str] = None,
) -> bool:
    """
    Coordinates advanced pattern/exemplar/neural inpainting:
    1. Inspects anchor page to obtain normalized bounding coordinates.
    2. Renders pages, applies phase-aligned donor / Big-LaMa healing per slide.
    3. Reconstructs PDF document.
    """
    import cv2
    import numpy as np
    from PIL import Image

    # Try importing fitz or fallback to Swift page extractor
    try:
        import fitz
        HAS_FITZ = True
    except ImportError:
        HAS_FITZ = False

    print(f"🔬 Inspecting Anchor Page {anchor_page} for exemplar/neural reconstruction...")
    inspect_res = inspect_anchor_page(
        input_pdf=input_pdf,
        anchor_page=anchor_page,
        zone=zone,
        text_filter=text_filter,
        explicit_box=explicit_box,
        preview_mask_path=preview_mask_path,
        dpi=dpi,
        padding=padding,
        extend_right=extend_right,
        extend_bottom=extend_bottom,
    )

    norm_box = inspect_res.get("normalizedBox")
    if not norm_box or len(norm_box) != 4:
        raise ValueError("Could not detect object bounds on anchor page.")

    norm_x, norm_y, norm_w, norm_h = norm_box
    matched_texts = inspect_res.get("textMatched", [])
    print(f"  [✓] Anchor Box: {norm_x:.4f}, {norm_y:.4f} ({norm_w:.4f} x {norm_h:.4f})")
    if matched_texts:
        print(f"  [✓] Target Text: {' | '.join(matched_texts)}")

    # Import exemplar healer functions
    sys.path.insert(0, str(SCRIPT_DIR))
    from exemplar_healer import heal_image_array

    if HAS_FITZ:
        doc = fitz.open(input_pdf)
        total_pages = len(doc)
        print(f"📄 Processing {total_pages} page(s) via PyMuPDF + Exemplar/Neural Engine ({strategy.upper()})...")

        # Parse target pages
        if pages.lower() == "all":
            target_set = set(range(total_pages))
        else:
            target_set = set()
            for part in pages.split(","):
                part = part.strip()
                if "-" in part:
                    s, e = map(int, part.split("-"))
                    target_set.update(range(s - 1, e))
                elif part.isdigit():
                    target_set.add(int(part) - 1)

        temp_dir = tempfile.mkdtemp(prefix="pdf_exemplar_")
        page_images = []

        zoom = dpi / 72.0
        mat = fitz.Matrix(zoom, zoom)

        for p_idx in range(total_pages):
            page = doc[p_idx]
            pix = page.get_pixmap(matrix=mat, alpha=False)
            img_bgr = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, 3)

            if p_idx in target_set:
                box_x = int(norm_x * pix.width)
                box_y = int(norm_y * pix.height)
                box_w = int(norm_w * pix.width)
                box_h = int(norm_h * pix.height)

                healed_bgr = heal_image_array(img_bgr, (box_x, box_y, box_w, box_h), strategy=strategy, seam_width=seam_width)
                out_page_path = os.path.join(temp_dir, f"page_{p_idx:04d}.png")
                cv2.imwrite(out_page_path, healed_bgr)
                page_images.append(out_page_path)
                print(f"  ↳ Healed Page {p_idx + 1}/{total_pages}")
            else:
                out_page_path = os.path.join(temp_dir, f"page_{p_idx:04d}.png")
                cv2.imwrite(out_page_path, img_bgr)
                page_images.append(out_page_path)

        # Assemble new PDF
        out_doc = fitz.open()
        for p_path in page_images:
            img_doc = fitz.open(p_path)
            rect = img_doc[0].rect
            pdf_bytes = img_doc.convert_to_pdf()
            img_pdf = fitz.open("pdf", pdf_bytes)
            out_doc.insert_pdf(img_pdf)
            img_doc.close()

        out_doc.save(output_pdf)
        out_doc.close()
        doc.close()
        shutil.rmtree(temp_dir, ignore_errors=True)
        print(f"✅ Successfully created cleaned PDF: {output_pdf}")
        return True
    else:
        # Fallback to native engine with auto mode if PyMuPDF not available
        print("Notice: PyMuPDF not found, delegating to native Apple Silicon engine...")
        return process_with_native_engine(
            input_pdf=input_pdf,
            output_pdf=output_pdf,
            anchor_page=anchor_page,
            zone=zone,
            text_filter=text_filter,
            explicit_box=explicit_box,
            mode="auto",
            dpi=dpi,
            pages=pages,
            exclude_pages=exclude_pages,
            padding=padding,
            extend_right=extend_right,
            extend_bottom=extend_bottom,
            preview_mask_path=preview_mask_path,
        )


def main():
    parser = argparse.ArgumentParser(
        description="PDF-Object-Remover: Detect on Anchor Page and Heal Across All Slides/Pages on macOS."
    )
    parser.add_argument("--input", "-i", required=True, help="Input PDF document path")
    parser.add_argument("--output", "-o", help="Output cleaned PDF document path")
    parser.add_argument("--anchor-page", "-p", type=int, default=1, help="Anchor reference page for detection (default: 1)")
    parser.add_argument("--filter", "-f", "--query", "-q", help="OCR text query or substring to detect on anchor page")
    parser.add_argument(
        "--zone", "-z",
        default="bottom-right",
        choices=[
            "bottom-right", "bottom-right-corner", "corner", "logo",
            "bottom-left", "top-right", "top-left", "footer", "header", "all", "custom"
        ],
        help="Spatial search zone preset (default: bottom-right)"
    )
    parser.add_argument("--min-x", type=float, help="Custom zone min X ratio (0.0 to 1.0)")
    parser.add_argument("--max-x", type=float, help="Custom zone max X ratio (0.0 to 1.0)")
    parser.add_argument("--min-y", type=float, help="Custom zone min Y ratio (0.0 to 1.0)")
    parser.add_argument("--max-y", type=float, help="Custom zone max Y ratio (0.0 to 1.0)")
    parser.add_argument("--box", "-b", help="Explicit box coordinates: 'x,y,w,h' (normalized 0..1 or pixels)")
    parser.add_argument(
        "--mode", "-m",
        default="auto",
        choices=["auto", "gradient", "solid", "exemplar", "lama", "composite"],
        help="Healing strategy per slide (default: auto)"
    )
    parser.add_argument("--dpi", type=float, default=300.0, help="PDF rendering resolution DPI (default: 300)")
    parser.add_argument("--pages", default="all", help="Target pages to heal (e.g. 'all', '1-5', '2,4,6')")
    parser.add_argument("--exclude-pages", default="", help="Pages to exempt from healing")
    parser.add_argument("--padding", type=int, default=4, help="Pixel padding around detected object (default: 4)")
    parser.add_argument("--feather", type=int, default=4, help="Edge feathering ramp width in pixels (default: 4)")
    parser.add_argument("--extend-right", action="store_true", help="Extend mask box flush to right page boundary")
    parser.add_argument("--extend-bottom", action="store_true", help="Extend mask box flush to bottom page boundary")
    parser.add_argument("--preview-mask", help="Save diagnostic preview mask image of anchor page")
    parser.add_argument("--inspect", action="store_true", help="Inspect anchor page and exit without modifying PDF")
    parser.add_argument("--json", action="store_true", help="Output inspection or stats in structured JSON format")

    args = parser.parse_args()

    if args.inspect:
        res = inspect_anchor_page(
            input_pdf=args.input,
            anchor_page=args.anchor_page,
            zone=args.zone,
            text_filter=args.filter,
            explicit_box=args.box,
            preview_mask_path=args.preview_mask,
            dpi=args.dpi,
            padding=args.padding,
            extend_right=args.extend_right,
            extend_bottom=args.extend_bottom,
            min_x=args.min_x,
            max_x=args.max_x,
            min_y=args.min_y,
            max_y=args.max_y,
        )
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            norm = res.get("normalizedBox", [0, 0, 0, 0])
            pix = res.get("pixelBox", [0, 0, 0, 0])
            bg = res.get("background", {})
            print(f"\n🎯 Anchor Page {args.anchor_page} Object Detection Summary:")
            print(f"  • Normalized Area: [x: {norm[0]:.4f}, y: {norm[1]:.4f}, w: {norm[2]:.4f}, h: {norm[3]:.4f}]")
            print(f"  • Pixel Area ({int(args.dpi)} DPI): {int(pix[0])},{int(pix[1])} {int(pix[2])}x{int(pix[3])} px")
            if res.get("textMatched"):
                print(f"  • Matched Text: {' | '.join(res['textMatched'])}")
            print(f"  • Background: {bg.get('hex', 'N/A')} (Gradient: {bg.get('isGradient', False)})")
            if args.preview_mask:
                print(f"  • Preview Mask: {args.preview_mask}")
        return

    if not args.output:
        print("Error: --output PDF path is required (unless using --inspect).", file=sys.stderr)
        sys.exit(1)

    if args.mode in ["exemplar", "lama", "composite"]:
        success = process_with_exemplar_engine(
            input_pdf=args.input,
            output_pdf=args.output,
            anchor_page=args.anchor_page,
            zone=args.zone,
            text_filter=args.filter,
            explicit_box=args.box,
            strategy=args.mode,
            dpi=args.dpi,
            pages=args.pages,
            exclude_pages=args.exclude_pages,
            padding=args.padding,
            seam_width=args.feather,
            extend_right=args.extend_right,
            extend_bottom=args.extend_bottom,
            preview_mask_path=args.preview_mask,
        )
    else:
        success = process_with_native_engine(
            input_pdf=args.input,
            output_pdf=args.output,
            anchor_page=args.anchor_page,
            zone=args.zone,
            text_filter=args.filter,
            explicit_box=args.box,
            mode=args.mode,
            dpi=args.dpi,
            pages=args.pages,
            exclude_pages=args.exclude_pages,
            padding=args.padding,
            feather=args.feather,
            extend_right=args.extend_right,
            extend_bottom=args.extend_bottom,
            preview_mask_path=args.preview_mask,
            min_x=args.min_x,
            max_x=args.max_x,
            min_y=args.min_y,
            max_y=args.max_y,
            json_output=args.json,
        )

    if not success:
        sys.exit(1)


if __name__ == "__main__":
    main()
