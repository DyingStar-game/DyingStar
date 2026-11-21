#!/usr/bin/env python3
"""random_faces.gd's or creator_survey.gd's renders packed for the rating page: per sample a tile of its two views
side by side, COLS x ROWS tiles a sheet, in the order of the run (a sample's sheet and place follow from its rank).

    python3 random_faces_sheets.py RENDERS_DIR --out DIR [--prefix b1] [--subject face|body]
reads RENDERS_DIR/faces.json (random_faces) or samples.json (creator_survey), writes DIR/<prefix>_<n>.jpg and
DIR/<prefix>.json ([id, ...] in sheet order).
"""
import argparse
import json
import os
import sys

from PIL import Image

COLS = 4
ROWS = 5
# Per subject: its two views, one view's size in a tile (px) and the crop of a render (fractions of its width /
# height: left, top, right; the bottom follows from the view's aspect).
SUBJECTS = {
    "face": {"views": ("front", "three_quarter"), "view": (240, 300), "crop": (0.12, 0.15, 0.88)},
    "body": {"views": ("front", "side"), "view": (200, 400), "crop": (0.0, 0.0, 1.0)},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("renders")
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", default="b1")
    ap.add_argument("--subject", choices=tuple(SUBJECTS), default="face")
    ap.add_argument("--quality", type=int, default=84)
    args = ap.parse_args()
    setup = SUBJECTS[args.subject]
    view_w, view_h = setup["view"]
    os.makedirs(args.out, exist_ok=True)
    listing = os.path.join(args.renders, "samples.json")
    if os.path.exists(listing):
        ids = [s["id"] for s in json.load(open(listing))]
    else:
        ids = [f["seed"] for f in json.load(open(os.path.join(args.renders, "faces.json")))]
    per = COLS * ROWS
    tile_w, tile_h = view_w * 2, view_h
    for n in range(0, len(ids), per):
        sheet = Image.new("RGB", (tile_w * COLS, tile_h * ROWS), (20, 22, 28))
        for k, sample in enumerate(ids[n:n + per]):
            x, y = (k % COLS) * tile_w, (k // COLS) * tile_h
            for v, view in enumerate(setup["views"]):
                im = Image.open(os.path.join(args.renders, "%d_%s.png" % (sample, view))).convert("RGB")
                w, h = im.size
                left, top, right = setup["crop"]
                box = (int(w * left), int(h * top), int(w * right),
                       int(h * top + w * (right - left) * view_h / view_w))
                sheet.paste(im.crop(box).resize((view_w, view_h), Image.LANCZOS), (x + v * view_w, y))
        sheet.save(os.path.join(args.out, "%s_%d.jpg" % (args.prefix, n // per)), quality=args.quality, optimize=True)
    with open(os.path.join(args.out, "%s.json" % args.prefix), "w") as f:
        json.dump(ids, f)
    print("%d samples, %d sheets in %s" % (len(ids), (len(ids) + per - 1) // per, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
