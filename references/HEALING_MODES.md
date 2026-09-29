# Healing Modes & Inpainting Strategies

The `pdf-object-remover` suite provides 6 distinct healing strategies, adapted from the `keynote-tools` engine:

---

## 1. Mode: `auto` (Default Smart Mode)
- **Best For**: Mixed presentations containing both solid, gradient, and light textured slides.
- **Algorithm**:
  - Samples the perimeter 14px ring on each individual page.
  - Computes channel variance $\sigma^2_R$.
  - If $\sigma^2_R < 6.0$: Classifies the background as **Solid**, fills with median RGB, and injects fine matched grain noise.
  - If $\sigma^2_R \ge 6.0$: Solves the 2D gradient plane equations ($R, G, B = ax + by + c$) and fills with the continuous planar gradient + matched noise.
  - Applies 4px perimeter feathering ramp.

---

## 2. Mode: `gradient` (2D Planar Surface Detrending)
- **Best For**: Pitch decks, keynote slides, and presentation hero slides featuring continuous linear or subtle radial color gradients.
- **Algorithm**:
  - Solves the least-squares normal equations across all boundary pixels to compute linear gradient slope $(a, b)$ and base offset $c$.
  - Synthesizes exact continuous color transition across the interior box.
  - Renders matched noise grain based on residual variance.

---

## 3. Mode: `solid` (Dominant Perimeter Color)
- **Best For**: Clean white or single-color background slides (e.g., standard reports, clean architectural line drawings).
- **Algorithm**:
  - Samples perimeter border pixels and computes the median RGB color.
  - Fills the interior box with the solid color and feathers the outer boundary.
  - Runs in less than 2 milliseconds per page on Apple Silicon.

---

## 4. Mode: `exemplar` (Phase-Aligned Donor Patch for Grids)
- **Best For**: Architectural drafting paper, blueprint grids, isometric graph paper, and repeating dot matrices.
- **Algorithm**:
  - Watermarks on grid paper break grid lines. Mode `exemplar` locates an unoccluded adjacent patch sharing the identical pattern.
  - Computes 2D normalized cross-correlation:
    $$R(x, y) = \frac{\sum_{x',y'} (T(x',y') - \bar{T})(I(x+x',y+y') - \bar{I})}{\sqrt{\sum (T - \bar{T})^2 \sum (I - \bar{I})^2}}$$
  - Aligns the donor patch with exact phase offset $(\Delta x, \Delta y)$ so grid lines continue seamlessly through the healed region.
  - Uses Euclidean distance transform (`cv2.distanceTransform`) to feather *only the outer perimeter seam*, preserving 100% of the internal grid geometry.

---

## 5. Mode: `lama` / `neural` (Big-LaMa Fast Fourier Inpainting)
- **Best For**: Complex non-linear illustrations, background photos, or artistic graphic textures.
- **Algorithm**:
  - Uses **Big-LaMa** (Resolution-Robust Large Mask Inpainting with Fast Fourier Convolutions).
  - Executes directly on Apple Silicon GPU using Metal Performance Shaders (`mps`).
  - Processes localized high-resolution crops ($400 \times 250\text{ px}$) to prevent downsampling blur on fine linework.

---

## 6. Mode: `composite` (Neural/Exemplar + Distance-Transform Seam Healing)
- **Best For**: High-stakes final documents where zero boundary edges or artifacts are permissible.
- **Algorithm**:
  - Reconstructs the target interior via LaMa Fast Fourier Inpainting or Exemplar donor patch.
  - Applies a Gaussian-feathered distance transform ramp strictly over a 6px boundary seam between the original page and the healed patch, eliminating edge cut lines.
