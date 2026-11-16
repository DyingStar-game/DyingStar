#!/usr/bin/env python3
"""The texture the generated hair's shell is drawn with (groom.py), made from nothing but random numbers.

    python3 tools/character/hair_groom/make_textures.py .

Writes assets/_universe/characters/human/hair/hair_shell.png, 256 x 256, tiling: the hair seen end-on, one
dot per hair. Data, not colour: R = how tall the hair under the texel stands (a shell layer keeps the
texels taller than itself), G = a random value per hair, B = the hair's full height.
"""
import os
import sys

import numpy as np
from PIL import Image

OUT_REL = "assets/_universe/characters/human/hair"
SEED = 20261113


def shell(rng):
    """Tiling dots, each a hair seen from its tip: R = its height, falling off from its centre."""
    size, hairs = 256, 2600
    image = np.zeros((size, size, 4))
    yy, xx = np.mgrid[0:size, 0:size]
    for _ in range(hairs):
        cx, cy = rng.uniform(0, size, 2)
        tall = rng.uniform(0.35, 1.0)
        radius = rng.uniform(1.6, 2.6)
        ident = rng.random()
        dx = np.minimum(np.abs(xx - cx), size - np.abs(xx - cx))
        dy = np.minimum(np.abs(yy - cy), size - np.abs(yy - cy))
        d = np.sqrt(dx ** 2 + dy ** 2) / radius
        near = d < 1.0
        h = tall * (1.0 - d ** 2)
        better = near & (h > image[..., 0])
        image[..., 0] = np.where(better, h, image[..., 0])
        image[..., 1] = np.where(better, ident, image[..., 1])
        image[..., 2] = np.where(better, tall, image[..., 2])
    image[..., 3] = 1.0
    return image


def save(image, path):
    Image.fromarray(np.clip(np.round(image * 255.0), 0, 255).astype(np.uint8), "RGBA").save(path)
    print(f"{path}: {image.shape[1]} x {image.shape[0]}, coverage {image[..., 3].mean() * 100:.0f} %")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = os.path.join(sys.argv[1], OUT_REL)
    os.makedirs(out, exist_ok=True)
    save(shell(np.random.default_rng(SEED)), os.path.join(out, "hair_shell.png"))
    with open(os.path.join(out, "hair_shell.txt"), "w") as f:
        f.write("Discord - ddurieux - 456525763215228948\n")


if __name__ == "__main__":
    main()
