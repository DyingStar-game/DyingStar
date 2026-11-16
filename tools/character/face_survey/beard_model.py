#!/usr/bin/env python3
"""The game's beard model (assets/_universe/characters/human/beard_model.json) for the photo-to-character's
PhotoBeard.scores: a ridge regression from PhotoBeard.measure's numbers, and the face's sex, to the facial hair
labels FFHQ's photos carry (features/json: Azure's facialHair moustache / beard / sideburns, 0..1 by tenths).

Its targets: "any" (the most of the moustache's and the beard's labels) and "beard" from every measure, for whether
there is facial hair and how much; then one per zone of the face from that zone's measures alone (and the face's),
so that a zone only scores what grows on it -- the labels go together (a beard nearly always comes with a
moustache), and a model of the beard's label from every measure reads it on the moustache: "moustache" (the
moustache's label), "chin", "cheeks" (the beard's) and "sideburns" (theirs). The neck's measures tell nothing
(shaven and bearded faces alike): PhotoBeard grows the neck with the beard's length.

    godot --headless --path . res://tools/character/face_survey/measure_beards.tscn -- --list=<paths.txt> --out=f.jsonl
    python3 beard_model.py f0.jsonl [f1.jsonl ...] --features ~/datasets/ffhq/features/json [--out beard_model.json]

Only the model's coefficients and the features' mean and spread are written: no photo nor any person's numbers.
"""
import argparse
import json
import os
import sys

import numpy as np

LABELS = ("moustache", "beard", "sideburns")
FACE = ("ref_l", "ref_chroma", "ref_tex", "hair_l", "hair_seen", "size", "male")
# target: (label, the zone whose measures it reads, or None for all)
TARGETS = {
    "any": ("any", None), "beard": ("beard", None), "moustache": ("moustache", "moustache"), "chin": ("beard", "chin"),
    "cheeks": ("beard", "cheeks"), "sideburns": ("sideburns", "sideburns"),
}


def load(paths, features_dir):
    names, xs, ys, males = None, [], [], []
    for path in paths:
        for line in open(path):
            row = json.loads(line)
            if "names" in row:
                names = row["names"]
                continue
            if not row.get("f") or abs(row.get("turn", 0.0)) > 0.25:
                continue
            ident = os.path.basename(row["path"])[:-4]
            d = json.load(open(os.path.join(features_dir, ident + ".json")))
            d = d[0] if isinstance(d, list) else d
            a = d["faceAttributes"]
            xs.append(row["f"])
            ys.append([a["facialHair"][t] for t in LABELS])
            males.append(1.0 if a["gender"] == "male" else 0.0)
    x = np.column_stack([np.array(xs, dtype=np.float64), np.array(males)])
    return names + ["male"], x, np.array(ys, dtype=np.float64)


def ridge(x, y, alpha):
    a = x.T @ x + alpha * np.eye(x.shape[1])
    return np.linalg.solve(a, x.T @ (y - y.mean(0))), y.mean(0)


def auc(score, positive):
    order = np.argsort(score)
    ranks = np.empty(len(score))
    ranks[order] = np.arange(1, len(score) + 1)
    n_pos = positive.sum()
    n_neg = len(score) - n_pos
    return (ranks[positive].sum() - n_pos * (n_pos + 1) / 2) / max(n_pos * n_neg, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("measures", nargs="+")
    ap.add_argument("--features", default=os.path.expanduser("~/datasets/ffhq/features/json"))
    ap.add_argument("--out", default="assets/_universe/characters/human/beard_model.json")
    args = ap.parse_args()
    names, x, labels = load(args.measures, args.features)
    labels = np.column_stack([labels, labels[:, :2].max(1)])  # + "any"
    columns = {name: k for k, name in enumerate(LABELS + ("any",))}
    y = np.column_stack([labels[:, columns[label]] for label, _ in TARGETS.values()])
    masks = np.array([[zone is None or n.startswith(zone + "_") or n in FACE for n in names]
                      for _, zone in TARGETS.values()])
    rng = np.random.default_rng(3)
    order = rng.permutation(len(x))
    test, check, train = order[: len(x) // 5], order[len(x) // 5: 2 * len(x) // 5], order[2 * len(x) // 5:]
    mean, std = x[train].mean(0), x[train].std(0) + 1e-6
    z = (x - mean) / std
    def fit(rows, alpha):
        w = np.zeros((x.shape[1], len(TARGETS)))
        b = np.zeros(len(TARGETS))
        for k in range(len(TARGETS)):
            wk, bk = ridge(z[rows][:, masks[k]], y[rows, k:k + 1], alpha)
            w[masks[k], k] = wk[:, 0]
            b[k] = bk[0]
        return w, b

    best = None
    for alpha in (1, 10, 30, 100, 300, 1000):
        w, b = fit(train, alpha)
        err = np.abs(z[check] @ w + b - y[check]).mean()
        if best is None or err < best[0]:
            best = (err, alpha)
    alpha = best[1]
    w, b = fit(np.r_[train, check], alpha)
    pred = np.clip(z[test] @ w + b, 0, 1)
    print(f"{len(x)} photos, {x.shape[1]} features, alpha {alpha}")
    for k, t in enumerate(TARGETS):
        mae = np.abs(pred[:, k] - y[test, k]).mean()
        base = np.abs(y[train, k].mean() - y[test, k]).mean()
        r = np.corrcoef(pred[:, k], y[test, k])[0, 1]
        aucs = [auc(pred[:, k], y[test, k] >= th) for th in (0.3, 0.5)]
        print(f"  {t:10s} MAE {mae:.3f} (mean {base:.3f}) r {r:.2f} | AUC >=0.3 {aucs[0]:.3f} >=0.5 {aucs[1]:.3f}")
    men = x[test, names.index("male")] == 1
    for k, t in enumerate(TARGETS):
        print(f"  {t:10s} men only AUC >=0.3 {auc(pred[men, k], y[test][men, k] >= 0.3):.3f}")
    try:
        from sklearn.ensemble import HistGradientBoostingRegressor
        for k, t in enumerate(TARGETS):
            gb = HistGradientBoostingRegressor(max_iter=300).fit(x[np.r_[train, check]], y[np.r_[train, check], k])
            p = gb.predict(x[test])
            print(f"  [ceiling: boosted trees] {t:10s} MAE {np.abs(p - y[test, k]).mean():.3f} "
                  f"r {np.corrcoef(p, y[test, k])[0, 1]:.2f} AUC >=0.3 {auc(p, y[test, k] >= 0.3):.3f}")
    except ImportError:
        pass
    order = np.argsort(-np.abs(w[:, 0]))[:10]
    print("  any's strongest features:", ", ".join(f"{names[i]} {w[i, 1]:+.3f}" for i in order))
    model = {
        "_doc": "PhotoBeard.scores' ridge regressions, learnt by tools/character/face_survey/beard_model.py on FFHQ "
                "photos' facial hair labels (each zone's from its own measures); only coefficients, no person's data.",
        "names": names,
        "mean": [round(float(v), 5) for v in mean],
        "std": [round(float(v), 5) for v in std],
        "targets": {t: {"w": [round(float(v), 6) for v in w[:, k]], "b": round(float(b[k]), 6)}
                    for k, t in enumerate(TARGETS)},
    }
    with open(args.out, "w") as f:
        json.dump(model, f, separators=(",", ":"))
    print("->", args.out)


if __name__ == "__main__":
    sys.exit(main())
