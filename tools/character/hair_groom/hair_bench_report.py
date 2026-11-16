#!/usr/bin/env python3
"""Measures and contact sheets for the hair bench (hair_bench.tscn).

    python3 hair_bench_report.py <bench dir A> [<bench dir B>] --out <report dir>

Each image is compared with the same figure bald and with the empty stage (the manifest names them):
  - footprint: where the hair changes the bald render (closed, holes filled): the hair's whole extent;
  - skin: the share of the footprint over the head where the bald render shows through unchanged
    (the skin seen between the hairs: the thinness the hair bench is about);
  - width: the figure's widest row across the cranium, with its hair, over the bald one's;
  - top: the hair's height over the crown, in head heights;
  - lum: the median luminance (linear) of the pixels the hair changed.
With two benches, each sheet sets A and B side by side and the summary prints both.
"""

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

CHANGED = 0.06  # sRGB difference that counts as changed
SKIN_SAME = 0.03  # sRGB difference under which the bald render shows through
HEAD_PX = {"hair": 470.0, "game": 100.0}  # a head's height in the bench's images, by lens


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def biggest(mask):
    labels, n = ndimage.label(mask)
    if n == 0:
        return mask
    sizes = ndimage.sum(mask, labels, range(1, n + 1))
    return labels == (1 + int(np.argmax(sizes)))


def measure(bench, entry):
    img = load(os.path.join(bench, entry["file"]))
    bald = load(os.path.join(bench, entry["bald"]))
    empty = load(os.path.join(bench, entry["empty"]))
    lens = "game" if entry["view"] == "game" else "hair"
    head_px = HEAD_PX[lens]
    figure = ndimage.binary_fill_holes(biggest(np.abs(bald - empty).max(axis=2) > CHANGED))
    diff = np.abs(img - bald).max(axis=2)
    changed = diff > CHANGED
    radius = 2 if lens == "game" else 6
    footprint = ndimage.binary_closing(changed, structure=np.ones((3, 3)), iterations=radius)
    footprint = ndimage.binary_fill_holes(footprint)
    labels, n = ndimage.label(footprint)
    if n:
        sizes = ndimage.sum(footprint, labels, range(1, n + 1))
        keep = np.isin(labels, 1 + np.nonzero(sizes >= (20 if lens == "game" else 200))[0])
        footprint = keep
    rows = np.nonzero(figure.any(axis=1))[0]
    top_bald = int(rows[0]) if rows.size else 0
    union = figure | footprint
    urows = np.nonzero(union.any(axis=1))[0]
    top_hair = int(urows[0]) if urows.size else top_bald
    # The cranium: from the bald crown down a third of a head.
    band = slice(top_bald, int(top_bald + 0.35 * head_px))

    def widest(mask):
        sub = mask[band]
        if not sub.any():
            return 0
        return max(int(np.ptp(np.nonzero(r)[0])) + 1 for r in sub if r.any())

    over_head = footprint & figure
    skin = float((diff[over_head] < SKIN_SAME).mean()) if over_head.any() else float("nan")
    hair_px = changed & footprint
    lum = float("nan")
    if hair_px.any():
        lin = linear(img[hair_px])
        lum = float(np.median(lin @ np.array([0.2126, 0.7152, 0.0722])))
    width_bald = widest(figure)
    crop = (
        max(0, int(np.nonzero(union.any(axis=0))[0][0]) - 20) if union.any() else 0,
        max(0, top_hair - 20),
        min(img.shape[1], int(np.nonzero(union.any(axis=0))[0][-1]) + 20) if union.any() else img.shape[1],
        min(img.shape[0], int(top_bald + 1.0 * head_px)),
    )
    return {
        "skin": skin,
        "width": widest(union) / width_bald if width_bald else float("nan"),
        "top": (top_bald - top_hair) / head_px,
        "lum": lum,
        "footprint": float(footprint.sum()) / head_px ** 2,
    }, crop


def tile(bench, entry, crop, size):
    im = Image.open(os.path.join(bench, entry["file"])).convert("RGB").crop(crop)
    im.thumbnail((size, size))
    canvas = Image.new("RGB", (size, size), (20, 22, 28))
    canvas.paste(im, ((size - im.width) // 2, (size - im.height) // 2))
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("benches", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tile", type=int, default=300)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    manifests = [json.load(open(os.path.join(b, "manifest.json"))) for b in args.benches]
    by_file = [{e["file"]: e for e in m} for m in manifests]
    files = [e["file"] for e in manifests[0] if all(e["file"] in f for f in by_file)]
    results = {}
    crops = {}
    for k, bench in enumerate(args.benches):
        for name in files:
            entry = by_file[k][name]
            res, crop = measure(bench, entry)
            results[(k, name)] = res
            if k == 0:
                crops[name] = crop
    with open(os.path.join(args.out, "metrics.json"), "w") as f:
        json.dump([{"bench": args.benches[k], "file": n, **r} for (k, n), r in results.items()], f, indent=1)
    # Summary: per job, the mean over its images.
    jobs = sorted({by_file[0][n]["job"] for n in files}, key=lambda j: files.index(next(n for n in files if by_file[0][n]["job"] == j)))
    keys = ["skin", "width", "top", "lum"]
    head = "%-22s" % "job" + "".join("%26s" % k for k in keys)
    print(head)
    for job in jobs:
        names = [n for n in files if by_file[0][n]["job"] == job]
        cells = []
        for key in keys:
            vals = [np.nanmean([results[(k, n)][key] for n in names]) for k in range(len(args.benches))]
            cells.append(" -> ".join("%.3f" % v for v in vals))
        print("%-22s" % job + "".join("%26s" % c for c in cells))
    # Sheets: one per job; a row per colour and light, a column per view (A | B side by side).
    size = args.tile
    for job in jobs:
        names = [n for n in files if by_file[0][n]["job"] == job]
        rows = sorted({(by_file[0][n]["colour"], by_file[0][n]["light"]) for n in names})
        views = list(dict.fromkeys(by_file[0][n]["view"] for n in names))
        nb = len(args.benches)
        sheet = Image.new("RGB", (len(views) * nb * size, len(rows) * (size + 18)), (10, 10, 12))
        draw = ImageDraw.Draw(sheet)
        for r, (colour, light) in enumerate(rows):
            for c, view in enumerate(views):
                name = next((n for n in names if by_file[0][n]["colour"] == colour and by_file[0][n]["light"] == light
                             and by_file[0][n]["view"] == view), None)
                if name is None:
                    continue
                for k in range(nb):
                    x = (c * nb + k) * size
                    y = r * (size + 18)
                    sheet.paste(tile(args.benches[k], by_file[k][name], crops[name], size), (x, y + 18))
                    m = results[(k, name)]
                    draw.text((x + 4, y + 3), "%s %s %s %s skin %.2f w %.2f" % (chr(65 + k) if nb > 1 else "", colour, light, view,
                              m["skin"], m["width"]), fill=(220, 220, 220))
        sheet.save(os.path.join(args.out, "sheet_%s.png" % job))
    print("sheets and metrics.json in", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
