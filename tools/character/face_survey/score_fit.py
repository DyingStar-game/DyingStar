#!/usr/bin/env python3
"""Score photo_fit.py on our own renders: how far each fitted face's shape is from the true one.

    python3 score_fit.py <human_bank.npz> <dir of photo_fit JSONs made with --ortho>

Per face: the rms distance (mm) over the face's front vertices between the true and the fitted shape, once the
fitted one is laid on the true one (similarity: a photo tells no absolute size), against the neutral face's.
"""
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fit import Bank  # noqa: E402
from regress import face_vertex_set, procrustes  # noqa: E402


def main():
    bank = Bank(sys.argv[1])
    bank.path = sys.argv[1]
    vertices = face_vertex_set(bank)
    cache = {}

    def shape(weights):
        pts = bank.base[vertices].astype(np.float64).copy()
        for key, w in weights.items():
            if w == 0.0:
                continue
            if key not in cache:
                cache[key] = bank.target(key)[vertices]
            pts += w * cache[key]
        return pts

    fitted_err, neutral_err = [], []
    for path in sorted(glob.glob(os.path.join(sys.argv[2], "*.json"))):
        result = json.load(open(path))
        if "truth" not in result:
            continue
        truth = shape({k: v for k, v in result["truth"].items() if not k.startswith("FACS_")})
        identity = result.get("identity", list(result["truth"]))
        fitted = shape({k: v for k, v in result["weights"].items() if k in identity})
        neutral = bank.base[vertices].astype(np.float64)
        fitted_err.append(np.sqrt(((procrustes(fitted, truth) - truth) ** 2).sum(1).mean()) * 1000)
        neutral_err.append(np.sqrt(((procrustes(neutral, truth) - truth) ** 2).sum(1).mean()) * 1000)
    fitted_err, neutral_err = np.array(fitted_err), np.array(neutral_err)
    print(f"{len(fitted_err)} faces: fitted {np.median(fitted_err):.2f} mm median ({np.percentile(fitted_err, 90):.2f} p90), "
          f"neutral face {np.median(neutral_err):.2f} mm; variance explained {1 - np.median(fitted_err ** 2) / np.median(neutral_err ** 2):.0%}")


if __name__ == "__main__":
    sys.exit(main())
