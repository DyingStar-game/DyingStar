#!/usr/bin/env python3
"""The game's hair library (assets/_universe/characters/human/hair_library.json) for the photo-to-character's
PhotoHair.match_cut: our own renders of random cuts, each seen from the front and turned 45 degrees each way,
measured by the game itself (measure_photos.tscn: PhotoHair.measure), with the cut's settings.

    ~/datasets/ffhq/hairlib2/render.sh 0 79            # human_preview.tscn --randcut, 3 cuts x 3 views a batch
    ls <tiles>/*.png > tiles.txt
    godot --headless --path . res://tools/character/face_survey/measure_photos.tscn -- --list=tiles.txt --out=m.json
    python3 pack_hair_library.py <cuts.txt> m.json [--out assets/_universe/characters/human/hair_library.json]

A tile is b<batch>_<k>_y<yaw>.png; cuts.txt has "<batch> <k> <cut bytes, hex>". Only our renders' numbers are
kept: no person's data.
"""
import argparse
import json
import os
import re
import sys

import numpy as np

FEATURES = ("turn", "amount", "crown", "forehead", "fringe", "fringe_side", "temples", "below_chin", "cropped", "width",
            "coherence")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cuts")
    ap.add_argument("measures")
    ap.add_argument("--out", default="assets/_universe/characters/human/hair_library.json")
    args = ap.parse_args()
    cuts = {}
    for line in open(args.cuts):
        b, k, key = line.split()
        cuts[(int(b), int(k))] = key
    entries = {}
    for m in json.load(open(args.measures)):
        name = os.path.basename(m["path"])
        found = re.match(r"b(\d+)_(\d+)_y(-?\d+)\.png", name)
        shape = m.get("hair_shape", {})
        if not found or not shape:
            continue
        b, k, yaw = int(found.group(1)), int(found.group(2)), found.group(3)
        if (b, k) not in cuts:
            continue
        entry = entries.setdefault((b, k), {"cut": cuts[(b, k)], "views": {}})
        entry["views"][yaw] = {f: round(float(shape[f]), 4) for f in FEATURES if f in shape}
    # Only cuts seen from the front, and at least one side.
    kept = [e for e in entries.values() if "0" in e["views"] and len(e["views"]) >= 2]
    turns = [e["views"]["45"]["turn"] for e in kept if "45" in e["views"]]
    spread = {}
    for f in FEATURES:
        values = [v[f] for e in kept for v in e["views"].values() if f in v and not (f == "coherence" and v[f] < 0)]
        spread[f] = round(float(np.std(values)), 4) if values else 1.0
    library = {
        "_doc": "Our renders of random hair cuts (human_preview.tscn --randcut), measured from the front and turned 45 degrees "
                "each way by PhotoHair.measure; pack_hair_library.py. No person's data.",
        "turn_45": "45" if np.median(turns) > 0 else "-45",
        "spread": spread,
        "cuts": kept,
    }
    with open(args.out, "w") as f:
        json.dump(library, f, separators=(",", ":"))
    print(f"{len(kept)} cuts of {len(entries)} ({sum(len(e['views']) for e in kept)} views) -> {args.out}; "
          f"the +45 view turns {np.median(turns):+.2f}")


if __name__ == "__main__":
    sys.exit(main())
