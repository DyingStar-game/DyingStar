#!/usr/bin/env python3
"""The creator's face limits (CreatorLimits), fitted on the rating page's verdicts of creator_survey.gd's series.

What the European series of 2026-11-20 showed (1 200 faces rated by eye, the base faces FLAME's alone):
- one slider alone, even at the end of its travel, broke 4 faces in 399: no slider needs a bound of its own;
- sliders moved together did, the mouth's first, then the eyes', the jaw's a little, the skull's, the nose's and the
  ears' hardly.
So a face carries a LOAD, E = sum over the catalogue's face tabs of weight_tab * (sum of the tab's squared slider
values), and the creator stops a slider where E would pass a BUDGET. The weights are a logistic regression of the
verdicts on the tabs' sums of squares, scaled to the heaviest tab's (1); the budget is the load at which a 1-D
logistic of the verdicts on log E reaches --target (the share of faces judged not human that is accepted at the
edge) -- on log E, since a face nobody touched is never judged not human (0 of 136).
FLAME's own sliders (the creator's overall shape axes) are real faces' directions: they carry no load.
--direction KEY:- (or :+) gives one slider, that way, a weight of its own, fitted alongside the tabs' (its squares
leave its tab's sum): for a slider that breaks faces sooner than its tab's others -- the lower lip's corners pulled
down did (counter-survey, 2026-11-20: 7 of the 12 faces still judged not human under the limits).
--cap KEY:+:0.8 (or :-) stops one slider, that way, at a value, outside any load: the body's sliders, which bodies
take well (2026-11-21, European bodies: 4 judged not human in 400 player-made, then 1 in 400 when each slider was
swept alone and each tab's moved together) -- but BodyType_Emaciated alone passed at 0.8 and broke at 1, as it did
with other thinning sliders at 0.75 and 0.87 (--cap BodyType_Emaciated:+:0.8).

Usage:
    fit_limits.py --series ~/datasets/creator_survey_eu2:verdicts_2026-11-20c:clip \\
                  --series ~/datasets/creator_survey_eu3:verdicts_2026-11-20d \\
                  --series ~/datasets/creator_survey_eu4:verdicts_2026-11-20e --target 0.03
A series is DIR:VERDICTS[:clip] -- DIR holding face/samples.json, VERDICTS the snapshot of the page's
*_face_verdicts collection (ArtifactData out_dir); with :clip a sample not clicked keeps CLIP's guess (face/clip.json,
for a series whose lots were marked seen), else it is OK. Only ids 1..--seen are read (the lots rated).
Writes assets/_universe/characters/human/creator_limits.json (never edit it by hand): rerun with another --target to
loosen or tighten, or turn CreatorLimits.strength down in game -- the looks players saved are never rewritten.
"""
import argparse
import glob
import json
import math
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
CATALOGUE = os.path.join(ROOT, "assets/_universe/characters/human/human_catalogue.json")
OUT = os.path.join(ROOT, "assets/_universe/characters/human/creator_limits.json")
TABS = ["head", "eyes", "nose", "mouth", "jaw", "ears"]
# A tab whose fitted weight is about nothing still carries a little load: a face of nothing but pushed ears is not
# what the verdicts saw, and must not be free to go anywhere.
LIGHTEST = 0.025


def logistic(X, y, steps=60000, rate=0.1):
    Xb = np.hstack([X, np.ones((len(X), 1))])
    w = np.zeros(Xb.shape[1])
    for _ in range(steps):
        p = 1.0 / (1.0 + np.exp(-Xb @ w))
        w -= rate * Xb.T @ (p - y) / len(y)
    return w


def features(sliders, tab_of, directions):
    """Per tab its sum of squares, then per direction (key, sign) its square -- out of its tab's sum."""
    tabs = dict.fromkeys(TABS, 0.0)
    own = [0.0] * len(directions)
    for k, v in sliders.items():
        hit = [i for i, (key, sign) in enumerate(directions) if key == k and (v < 0) == (sign == "-")]
        if hit:
            own[hit[0]] += v * v
        elif tab_of.get(k) in tabs:
            tabs[tab_of[k]] += v * v
    return [tabs[t] for t in TABS] + own


def load(spec, seen, tab_of, directions):
    parts = os.path.expanduser(spec).split(":")
    root, verdicts, clip_default = parts[0], parts[1], len(parts) > 2 and parts[2] == "clip"
    samples = json.load(open(os.path.join(root, "face", "samples.json")))
    mine = {}
    for f in glob.glob(os.path.join(root, verdicts, "*_face_verdicts", "*.json")):
        d = json.load(open(f))
        mine[int(d["id"])] = bool(d["bad"])
    clip = json.load(open(os.path.join(root, "face", "clip.json")))["samples"] if clip_default else {}
    rows = []
    for s in samples:
        if s["id"] > seen:
            continue
        bad = mine[s["id"]] if s["id"] in mine else clip.get(str(s["id"]), {}).get("guess") == "bad"
        rows.append((features(s["sliders"], tab_of, directions), float(bad)))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--series", action="append", required=True)
    ap.add_argument("--seen", type=int, default=400, help="ids rated in each series (1..N)")
    ap.add_argument("--target", type=float, default=0.03, help="share of faces judged not human accepted at the budget")
    ap.add_argument("--direction", action="append", default=[], help="KEY:- or KEY:+, a weight of its own")
    ap.add_argument("--cap", action="append", default=[], help="KEY:+:V or KEY:-:V, one slider stopped at V that way")
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    tab_of = {e["key"]: e["tab"] for e in json.load(open(CATALOGUE))["modifiers"]}
    directions = [tuple(d.rsplit(":", 1)) for d in a.direction]
    rows = [r for spec in a.series for r in load(spec, a.seen, tab_of, directions)]
    X = np.array([r[0] for r in rows])
    y = np.array([r[1] for r in rows])
    w = logistic(X, y)[:-1]
    heaviest = float(w[:len(TABS)].max())
    weights = {t: round(max(float(w[i]) / heaviest, LIGHTEST), 3) for i, t in enumerate(TABS)}
    own = {}
    for i, (key, sign) in enumerate(directions):
        own.setdefault(key, {})[sign] = round(max(float(w[len(TABS) + i]) / heaviest, LIGHTEST), 3)
    load_of = X @ np.array([weights[t] for t in TABS] + [own[k][sg] for k, sg in directions])
    moved = load_of > 1e-6
    a1, b1 = logistic(np.log(load_of[moved])[:, None], y[moved])
    budget = math.exp((math.log(a.target / (1.0 - a.target)) - b1) / a1)
    inside = load_of <= budget
    print(f"{len(rows)} faces, {int(y.sum())} not human; weights {weights}, directions {own}")
    print(f"P(not human) = logistic({a1:.3f} * ln E + {b1:.3f}); budget E <= {budget:.3f} at {a.target:.1%}: "
          f"{int(y[inside].sum())} / {int(inside.sum())} faces within it judged not human")
    edges = [0, 1e-6, 0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 1, 1.5, 2, 3, 1e9]
    for lo, hi in zip(edges, edges[1:]):
        m = (load_of >= lo) & (load_of < hi)
        if m.sum():
            mid = math.sqrt(max(lo, 1e-3) * min(hi, 4.0))  # the bin's middle, on the log scale the fit is on
            fitted = 1.0 / (1.0 + math.exp(-(a1 * math.log(mid) + b1))) if lo > 0 else 0.0
            print(f"  E {lo:4.2f}..{hi:<5.4g} {int(y[m].sum()):3d} / {int(m.sum()):3d} not human ({y[m].mean():4.0%}), fit {fitted:4.0%}")
    for t in TABS:
        print(f"  {t:6s} alone: sum of squares <= {budget / weights[t]:.2f} (one slider up to "
              f"{min(1.0, math.sqrt(budget / weights[t])):.2f})")
    for key, signs in own.items():
        for sign, wt in signs.items():
            print(f"  {key} {sign}: one slider up to {min(1.0, math.sqrt(budget / wt)):.2f}")
    caps = {}
    for c in a.cap:
        key, sign, v = c.rsplit(":", 2)
        caps.setdefault(key, {})[sign] = round(float(v), 3)
        print(f"  {key} {sign}: capped at {float(v):.2f}")
    out = {
        "_doc": "Generated by tools/character/face_survey/fit_limits.py from the creator survey's verdicts. Never edit "
                "by hand: rerun it (another --target), or set CreatorLimits.strength.",
        "tabs": weights,
        "directions": own,
        "caps": caps,
        "budget": round(float(budget), 3),
        "fit": {"slope": round(float(a1), 4), "bias": round(float(b1), 4), "target": a.target,
                "faces": len(rows), "not_human": int(y.sum())},
    }
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("wrote", a.out)


if __name__ == "__main__":
    sys.exit(main())
