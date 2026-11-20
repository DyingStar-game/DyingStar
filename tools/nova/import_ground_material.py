"""A PBR ground material -> the three images Nova's ground reads.

    python tools/nova/import_ground_material.py <albedo> <normal_gl> <orm> <height> <out_dir> <name> [source text]

Writes tex_<name>_albedo.png (grey, matched to the light mid-grey of the other Nova grounds: the rock's
colour tints it in game), tex_<name>_normal.png (OpenGL convention) and tex_<name>_orh.png (occlusion,
roughness, height in R, G, B), plus source.txt. For Material Maker: export with
    material_maker --export-material --target Godot -o <dir> <file.ptex>
and pass its _albedo, _normal, _orm and _heightmap images.
"""
import os
import sys

import numpy as np
from PIL import Image

# Linear mean and spread of a Nova ground's grey albedo (mat_gravel_slate_040, mat_rock_cracked_062).
MEAN = 0.468
SPREAD = 0.16


def lin(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def srgb(x):
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.clip(x, 0, 1) ** (1 / 2.4) - 0.055)


def main():
    albedo, normal, orm, height, out_dir, name = sys.argv[1:7]
    source = sys.argv[7] if len(sys.argv) > 7 else ''
    os.makedirs(out_dir, exist_ok=True)
    grey = lin(np.asarray(Image.open(albedo).convert('RGB'), dtype=np.float64) / 255.0).mean(axis=2)
    grey = np.clip((grey - grey.mean()) / max(grey.std(), 1e-6) * SPREAD + MEAN, 0.02, 1.0)
    g8 = (srgb(grey) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(np.stack([g8, g8, g8], axis=2)).save(os.path.join(out_dir, 'tex_%s_albedo.png' % name))
    Image.open(normal).convert('RGB').save(os.path.join(out_dir, 'tex_%s_normal.png' % name))
    o = Image.open(orm).convert('RGB').split()
    h = Image.open(height).convert('L')
    # The height stretched to the whole range: Nova blends materials and tiles by it.
    ha = np.asarray(h, dtype=np.float64)
    ha = (ha - ha.min()) / max(ha.max() - ha.min(), 1.0) * 255.0
    Image.merge('RGB', [o[0], o[1], Image.fromarray(ha.astype(np.uint8))]).save(
        os.path.join(out_dir, 'tex_%s_orh.png' % name))
    if source:
        open(os.path.join(out_dir, 'source.txt'), 'w', encoding='utf-8').write(source + '\n')
    print('ok', sorted(os.listdir(out_dir)))


main()
