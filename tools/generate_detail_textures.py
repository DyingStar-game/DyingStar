#!/usr/bin/env python3
"""Generate tileable detail textures for planet terrain biomes.

Each texture is a 512×512 grayscale PNG centred around mid-grey (0.5).
Values > 0.5 brighten the base biome colour; values < 0.5 darken it.
The textures are naturally tileable because they are built entirely in
Fourier space (DFT is periodic by definition).

Generated textures
------------------
 0  detail_blank.png     – flat 50 % grey, used as "no detail"
 1  detail_sand.png      – fine ripple pattern
 2  detail_rock.png      – rough multi-scale fractal
 3  detail_grass.png     – high-frequency with patchy low-frequency
 4  detail_forest.png    – scattered darker leaf / twig spots
 5  detail_snow.png      – very gentle, almost smooth
 6  detail_volcanic.png  – dark with bright vein ridges
 7  detail_mud.png       – smooth with subtle patches
 8  detail_regolith.png  – fine dusty grain, low contrast
 9  detail_cracked.png   – Voronoi cell-edge cracks
10  detail_crystal.png   – faceted bright spots
11  detail_martian.png   – directional wind ripples

Usage
-----
    python tools/generate_detail_textures.py

All files are written to  assets/textures/planet/detail/
"""

from __future__ import annotations

import os
import sys

import numpy as np
from numpy.typing import NDArray
from PIL import Image

# Optional – only needed for the "cracked" texture and the "martian" texture
try:
    from scipy.ndimage import gaussian_filter
except ImportError:
    gaussian_filter = None

SIZE = 512
OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "textures", "planet", "detail",
)


# ═══════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════

def _bandpass_noise(
    size: int,
    freq_min: float,
    freq_max: float,
    seed: int,
) -> NDArray[np.float64]:
    """Tileable noise via FFT bandpass filtering of white noise."""
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((size, size))

    F = np.fft.fftshift(np.fft.fft2(white))

    y, x = np.ogrid[-size // 2 : size // 2, -size // 2 : size // 2]
    r = np.sqrt(x * x + y * y).astype(np.float64)
    centre = (freq_min + freq_max) * 0.5
    sigma = max((freq_max - freq_min) * 0.5, 1.0)
    bp = np.exp(-0.5 * ((r - centre) / sigma) ** 2)

    result = np.real(np.fft.ifft2(np.fft.ifftshift(F * bp)))
    lo, hi = result.min(), result.max()
    if hi - lo > 0:
        result = (result - lo) / (hi - lo)
    else:
        result = np.full_like(result, 0.5)
    return result


def _fbm(
    size: int,
    base_freq: float = 8,
    octaves: int = 4,
    persistence: float = 0.5,
    seed: int = 42,
) -> NDArray[np.float64]:
    """Fractal Brownian Motion (tileable, multi-octave bandpass noise)."""
    result = np.zeros((size, size), dtype=np.float64)
    amp = 1.0
    total = 0.0
    for i in range(octaves):
        f = base_freq * (2 ** i)
        layer = _bandpass_noise(size, f * 0.7, f * 1.3, seed + i * 137)
        result += layer * amp
        total += amp
        amp *= persistence
    result /= total
    return result


def _adjust(
    arr: NDArray[np.float64],
    contrast: float = 1.0,
    brightness: float = 0.5,
) -> NDArray[np.float64]:
    """Contrast + brightness; output clamped to [0, 1]."""
    return np.clip((arr - 0.5) * contrast + brightness, 0.0, 1.0)


def _save(arr: NDArray[np.float64], name: str) -> None:
    """Save as 8-bit grayscale PNG."""
    img = Image.fromarray((arr * 255).astype(np.uint8), "L")
    path = os.path.join(OUTPUT_DIR, name)
    img.save(path, optimize=True)
    print(f"  ✓ {name:30s}  ({img.size[0]}×{img.size[1]})")


# ═══════════════════════════════════════════════════════════════════════════
# Generators
# ═══════════════════════════════════════════════════════════════════════════

def gen_blank() -> None:
    _save(np.full((SIZE, SIZE), 0.5), "detail_blank.png")


def gen_sand() -> None:
    n = _fbm(SIZE, base_freq=16, octaves=3, persistence=0.4, seed=1)
    _save(_adjust(n, contrast=0.4, brightness=0.5), "detail_sand.png")


def gen_rock() -> None:
    n = _fbm(SIZE, base_freq=6, octaves=5, persistence=0.6, seed=2)
    _save(_adjust(n, contrast=0.7, brightness=0.48), "detail_rock.png")


def gen_grass() -> None:
    hi = _fbm(SIZE, base_freq=20, octaves=3, persistence=0.5, seed=3)
    lo = _fbm(SIZE, base_freq=4, octaves=2, persistence=0.5, seed=33)
    n = hi * 0.6 + lo * 0.4
    _save(_adjust(n, contrast=0.45, brightness=0.52), "detail_grass.png")


def gen_forest() -> None:
    hi = _fbm(SIZE, base_freq=8, octaves=4, persistence=0.55, seed=4)
    lo = _fbm(SIZE, base_freq=3, octaves=2, persistence=0.4, seed=44)
    n = hi * 0.5 + lo * 0.5
    _save(_adjust(n, contrast=0.5, brightness=0.47), "detail_forest.png")


def gen_snow() -> None:
    n = _fbm(SIZE, base_freq=4, octaves=2, persistence=0.3, seed=5)
    _save(_adjust(n, contrast=0.2, brightness=0.55), "detail_snow.png")


def gen_volcanic() -> None:
    n = _fbm(SIZE, base_freq=6, octaves=4, persistence=0.6, seed=6)
    # Create ridge-like veins from the noise field.
    ridge = 1.0 - np.abs(n - 0.5) * 2.0
    combined = n * 0.4 + ridge * 0.6
    _save(_adjust(combined, contrast=0.65, brightness=0.42), "detail_volcanic.png")


def gen_mud() -> None:
    n = _fbm(SIZE, base_freq=6, octaves=3, persistence=0.4, seed=7)
    _save(_adjust(n, contrast=0.3, brightness=0.48), "detail_mud.png")


def gen_regolith() -> None:
    n = _fbm(SIZE, base_freq=24, octaves=2, persistence=0.35, seed=8)
    _save(_adjust(n, contrast=0.25, brightness=0.5), "detail_regolith.png")


def gen_cracked() -> None:
    """Voronoi cell edges → crack pattern.  Tileable by 3×3 tiling trick."""
    rng = np.random.default_rng(9)
    n_pts = 150
    pts = rng.random((n_pts, 2))

    # Tile points in a 3×3 grid so the centre tile wraps seamlessly.
    tiled = []
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            tiled.append(pts + np.array([dx, dy]))
    tiled = np.vstack(tiled)

    y_grid, x_grid = np.mgrid[0:SIZE, 0:SIZE].astype(np.float64) / SIZE

    # For each pixel, find the two closest seed points.
    # Difference between d2 and d1 → thin edges at cell boundaries.
    d1 = np.full((SIZE, SIZE), 1e9)
    d2 = np.full((SIZE, SIZE), 1e9)
    for px, py in tiled:
        d = np.sqrt((x_grid - px) ** 2 + (y_grid - py) ** 2)
        mask2 = d < d2
        d2 = np.where(mask2, d, d2)
        swap = d2 < d1
        d1, d2 = np.where(swap, d2, d1), np.where(swap, d1, d2)

    edge = d2 - d1
    edge -= edge.min()
    if edge.max() > 0:
        edge /= edge.max()

    # Invert: thin bright cracks on dark background, then remap for shader.
    cracks = 1.0 - edge
    cracks = cracks ** 3  # sharpen the cracks
    _save(_adjust(cracks, contrast=0.55, brightness=0.5), "detail_cracked.png")


def gen_crystal() -> None:
    n = _fbm(SIZE, base_freq=12, octaves=3, persistence=0.5, seed=10)
    # Create faceted sparkle look.
    faceted = np.where(n > 0.6, n * 1.4, n * 0.7)
    faceted = np.clip(faceted, 0.0, 1.0)
    _save(_adjust(faceted, contrast=0.6, brightness=0.5), "detail_crystal.png")


def gen_martian() -> None:
    base = _fbm(SIZE, base_freq=10, octaves=3, persistence=0.45, seed=11)
    directional = _bandpass_noise(SIZE, 8, 20, seed=111)

    if gaussian_filter is not None:
        # Anisotropic blur: elongate horizontally to simulate wind patterns.
        stretched = gaussian_filter(directional, sigma=[1.0, 8.0])
        lo, hi = stretched.min(), stretched.max()
        if hi - lo > 0:
            stretched = (stretched - lo) / (hi - lo)
        else:
            stretched = np.full_like(stretched, 0.5)
    else:
        stretched = directional

    combined = base * 0.5 + stretched * 0.5
    _save(_adjust(combined, contrast=0.4, brightness=0.48), "detail_martian.png")


# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════

def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print(f"Generating detail textures in {OUTPUT_DIR}")
    print("=" * 60)

    gen_blank()      # 0
    gen_sand()       # 1
    gen_rock()       # 2
    gen_grass()      # 3
    gen_forest()     # 4
    gen_snow()       # 5
    gen_volcanic()   # 6
    gen_mud()        # 7
    gen_regolith()   # 8
    gen_cracked()    # 9
    gen_crystal()    # 10
    gen_martian()    # 11

    print("=" * 60)
    count = len([f for f in os.listdir(OUTPUT_DIR) if f.endswith(".png")])
    print(f"Done — {count} textures in {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
