"""Encode the dumped Vitruvian textures (dump_textures.py's .npy) as the game's WebP files.

  *_light, *_dark, *_colour   linear colour -> sRGB, lossy WebP
  *_height                    -> tangent-space normal map (OpenGL convention, as Godot reads them), its
                                 strength set so the 99th percentile slope is SLOPE_P99: the heights have no
                                 stated unit, and what matters is that pores and folds read at a glance
  *_roughness                 -> grey WebP

Writes assets/_universe/characters/human/skin/vitruvian_<name>.webp and the credit file vitruvian.txt.

usage: python3 convert_textures.py <dump dir> <project root>
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

OUT_REL = "assets/_universe/characters/human/skin"
CREDIT = "Blender Artists - Hopefullyidont1 - https://blenderartists.org/t/open-source-customizable-digital-human-vitruvian-project/1457388 - CC0\n"
SLOPE_P99 = {"default": 0.45, "age_height": 0.6, "tension": 0.6}
SKIP = ("tension",)  # the expression wrinkles: encoded when the face units use them


def to_srgb(linear: np.ndarray) -> np.ndarray:
    linear = np.clip(linear, 0.0, 1.0)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * np.power(linear, 1.0 / 2.4) - 0.055)


def normal_from_height(height: np.ndarray, slope_p99: float) -> np.ndarray:
    du = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    dv = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    scale = slope_p99 / max(float(np.percentile(np.hypot(du, dv), 99.0)), 1e-9)
    n = np.stack([-du * scale, dv * scale, np.ones_like(height)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


def main():
    dump, root = sys.argv[1], sys.argv[2]
    out_dir = os.path.join(root, OUT_REL)
    os.makedirs(out_dir, exist_ok=True)
    total = 0
    for path in sorted(glob.glob(os.path.join(dump, "*.npy"))):
        name = os.path.basename(path)[:-4]
        if any(s in name for s in SKIP):
            continue
        data = np.load(path).astype(np.float32)
        dst = os.path.join(out_dir, f"vitruvian_{name.replace('_height', '_normal')}.webp")
        if data.shape[2] == 3:
            Image.fromarray((to_srgb(data) * 255.0 + 0.5).astype(np.uint8), "RGB").save(dst, "WEBP", quality=92, method=6)
        elif name.endswith("height"):
            kind = "age_height" if "age_height" in name else "default"
            normal = normal_from_height(data[..., 0], SLOPE_P99[kind])
            Image.fromarray((normal * 255.0 + 0.5).astype(np.uint8), "RGB").save(dst, "WEBP", quality=95, method=6)
        else:
            Image.fromarray((np.clip(data[..., 0], 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8), "L").save(dst, "WEBP", quality=90, method=6)
        total += os.path.getsize(dst)
        print(f"{os.path.basename(dst)}: {data.shape[1]} px, {os.path.getsize(dst) / 1e6:.2f} MB")
    with open(os.path.join(out_dir, "vitruvian.txt"), "w") as f:
        f.write(CREDIT)
    print(f"total {total / 1e6:.1f} MB in {out_dir}")


if __name__ == "__main__":
    main()
