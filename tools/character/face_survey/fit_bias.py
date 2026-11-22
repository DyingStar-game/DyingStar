#!/usr/bin/env python3
"""What the photo fit adds to any face: renders of known random faces (creator_survey.tscn --controls --no-types)
fitted as FFHQ's photos are (fit_photos.tscn, same origin), against the sliders they were made with -> per sex and
shape key, the fit's value for a face whose true value is 0 (a regression's intercept where the key varies, its mean
otherwise), in stored slider values. face_types.py --fit-bias takes it off every photo.

Found 2026-11-21: the types' mean face was 0.5-1 sd wider (face, cheekbones, jaw) than FFHQ's photos of its origin,
measured with MediaPipe -- the fit's outline, not the photos.

    python3 fit_bias.py --fits '<renders>/fit_*.jsonl' --samples <dir>/samples.json [--samples ...] --out bias.json
"""
import argparse
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from face_types import FLAME_PREFIX, JAW_KEYS, NOSE_KEYS  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fits", required=True, help="glob of fit_photos.tscn's JSON lines, over the renders")
    ap.add_argument("--samples", action="append", required=True, help="the renders' samples.json (one per folder)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    truth = {}
    for f in a.samples:
        d = os.path.dirname(os.path.abspath(os.path.expanduser(f)))
        for x in json.load(open(os.path.expanduser(f))):
            truth[os.path.join(d, "%d_front.png" % x["id"])] = x
    rows = []
    for f in sorted(glob.glob(os.path.expanduser(a.fits))):
        for line in open(f):
            r = json.loads(line)
            if r.get("found", True) and r["path"] in truth:
                second = sorted(truth[r["path"]]["origins"])[-2]
                if second <= 0.05:  # a face of one origin, as the fit's base is: a mixed one leans another way
                    rows.append(r)
    keys = sorted({k for r in rows for k in r["weights"]
                   if k.startswith(FLAME_PREFIX) or k in JAW_KEYS or k in NOSE_KEYS})
    out = {}
    for sex, fem in (("female", True), ("male", False)):
        mine = [r for r in rows if bool(truth[r["path"]]["female"]) == fem]
        fit = np.array([[r["weights"].get(k, 0.0) for k in keys] for r in mine])
        true = np.array([[truth[r["path"]]["sliders"].get(k, 0.0) for k in keys] for r in mine])
        bias = {}
        for j, k in enumerate(keys):
            if true[:, j].std() > 1e-3:
                slope, icpt = np.polyfit(true[:, j], fit[:, j], 1)
            else:
                icpt = fit[:, j].mean()
            if abs(icpt) >= 0.005:
                bias[k] = round(float(icpt), 4)
        out[sex] = bias
        top = sorted(bias.items(), key=lambda kv: -abs(kv[1]))[:6]
        print(f"{sex}: {len(mine)} renders, {len(bias)} keys; largest {top}")
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("wrote", a.out)


if __name__ == "__main__":
    sys.exit(main())
