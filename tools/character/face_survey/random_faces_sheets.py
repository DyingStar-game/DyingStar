#!/usr/bin/env python3
"""random_faces.gd's renders packed for the rating page: per face a tile of its front and three-quarter views side by
side, COLS x ROWS tiles a sheet, in seed order (a face's sheet and place follow from its rank in the batch).

    python3 random_faces_sheets.py FACES_DIR --out DIR [--prefix b1]
writes DIR/<prefix>_<n>.jpg and DIR/<prefix>.json ([seed, ...] in sheet order).
"""
import argparse
import json
import os
import sys

from PIL import Image

COLS = 4
ROWS = 5
VIEW = (240, 300)  # one view in a tile (px)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("faces")
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", default="b1")
    ap.add_argument("--quality", type=int, default=84)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    faces = json.load(open(os.path.join(args.faces, "faces.json")))
    seeds = [f["seed"] for f in faces]
    per = COLS * ROWS
    tile_w, tile_h = VIEW[0] * 2, VIEW[1]
    for n in range(0, len(seeds), per):
        sheet = Image.new("RGB", (tile_w * COLS, tile_h * ROWS), (20, 22, 28))
        for k, seed in enumerate(seeds[n:n + per]):
            x, y = (k % COLS) * tile_w, (k // COLS) * tile_h
            for v, view in enumerate(("front", "three_quarter")):
                im = Image.open(os.path.join(args.faces, "%d_%s.png" % (seed, view))).convert("RGB")
                # The head fills the upper middle of a render: crop to it.
                w, h = im.size
                box = (int(w * 0.12), int(h * 0.15), int(w * 0.88), int(h * 0.15 + w * 0.76 * VIEW[1] / VIEW[0]))
                sheet.paste(im.crop(box).resize(VIEW, Image.LANCZOS), (x + v * VIEW[0], y))
        sheet.save(os.path.join(args.out, "%s_%d.jpg" % (args.prefix, n // per)), quality=args.quality, optimize=True)
    with open(os.path.join(args.out, "%s.json" % args.prefix), "w") as f:
        json.dump(seeds, f)
    print("%d faces, %d sheets in %s" % (len(seeds), (len(seeds) + per - 1) // per, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
