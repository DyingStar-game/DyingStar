#!/usr/bin/env python3
"""Fit the character model to faces seen by MediaPipe: which slider values make our head land on a face's
landmarks. Used to measure what the creator can and cannot reach (tools/character/face_survey).

    python3 fit.py <human_bank.npz> <corr.npz> <landmarks.npz> <out.npz> [--truth]

Model: landmark k of a face = s R (P0[k] + sum_t w_t D_t[k]) + T, where P0 and D_t are the neutral head and
the bank's shape keys sampled at the landmark (correspond.py), and s R T a similarity (the photo's scale,
the head's pose). Alternating: the similarity by Umeyama's method, then the weights by bounded least
squares with a ridge -- so a weight the landmarks do not see stays near zero. Expression keys (a smile, an
open jaw, raised brows) are fitted alongside and kept apart: FFHQ smiles a lot, and a smile is not a face.

--truth: the landmarks come from render_heads.tscn, whose JSON beside each image gives the true weights;
then the fit is scored against them (how well the creator's own faces are recovered).
"""
import argparse
import json
import os
import sys

import numpy as np
from scipy.optimize import lsq_linear

# What a face is made of: the creator's face sliders (catalogue tabs), the origins, gender and age.
FACE_TABS = ("head", "eyes", "nose", "mouth", "jaw", "ears")
MACRO_KEYS = ("Gender_Female", "Gender_Male", "Age_Old")
# What a face is DOING: kept apart from who it is.
EXPRESSION_KEYS = (
    "FACS_Happy", "FACS_Smile_Lips_Closed", "FACS_Mouth_Large_Opened", "FACS_Jaw_Lower", "FACS_aa_02",
    "FACS_Eyes_Squint", "FACS_Lower_Eyelid_Squint", "FACS_Eyebrows_Raised_Left", "FACS_Eyebrows_Raised_Right",
    "FACS_Eyebrows_Frown_Left", "FACS_Eyebrows_Frown_Right", "FACS_Cheeks_Raised_Left", "FACS_Cheeks_Raised_Right",
    "FACS_Lips_Up_Raised_M", "FACS_Lips_Dn_Lower_M", "FACS_Lips_Up_Corner_Wide_Left", "FACS_Lips_Up_Corner_Wide_Right",
    "FACS_Kiss", "FACS_Eyes_Closed_Left", "FACS_Eyes_Closed_Right", "FACS_Sad", "FACS_Angry",
)
RIDGE_IDENTITY = 0.004  # how much a face slider's weight costs (in the landmarks' squared metres, scaled)
RIDGE_EXPRESSION = 0.005
DEPTH_WEIGHT = 0.15  # MediaPipe's depth is a learned estimate, far noisier than x, y
ITERATIONS = 8


class Bank:
    def __init__(self, path):
        b = np.load(path, allow_pickle=True)
        self.names = [str(n) for n in b["target_names"]]
        self.base = b["base"].astype(np.float64)
        self.scale = b["target_scale"]
        self.start = b["target_delta_start"]
        self.count = b["target_count"]
        self.dense = b["target_dense"]
        self.sparse_start = b["target_sparse_start"]
        self.sparse = b["sparse_index"]
        self.delta = b["delta"]
        cat = json.loads(str(b["catalogue_json"])) if "catalogue_json" in b.files else None
        self.catalogue = cat

    def target(self, name):
        """Dense (n, 3) deltas of a target, in metres."""
        t = self.names.index(name)
        n, s, c = len(self.base), int(self.start[t]), int(self.count[t])
        d = self.delta[s:s + 3 * c].astype(np.float64).reshape(-1, 3) * float(self.scale[t])
        out = np.zeros((n, 3))
        if self.dense[t]:
            out[:c] = d
        else:
            idx = self.sparse[int(self.sparse_start[t]):int(self.sparse_start[t]) + c].astype(np.int64)
            out[idx] = d
        return out


def face_keys(bank, catalogue_path):
    cat = json.load(open(catalogue_path))
    keys = [m["key"] for m in cat["modifiers"] if m["tab"] in FACE_TABS and m["key"] != "Generic_Assymetry"]
    keys += list(cat["origins"]) + list(MACRO_KEYS)
    return [k for k in keys if k in bank.names], [k for k in EXPRESSION_KEYS if k in bank.names]


def sample(points, corr):
    """Landmark positions on a mesh (n, 3) -> (478, 3)."""
    return (points[corr["vertices"]] * corr["bary"][..., None]).sum(1)


def umeyama(src, dst, w):
    """Similarity (s, R, t) minimising sum w |s R src + t - dst|^2."""
    w = w / w.sum()
    mu_s, mu_d = (src * w[:, None]).sum(0), (dst * w[:, None]).sum(0)
    a, b = src - mu_s, dst - mu_d
    cov = (b * w[:, None]).T @ a
    u, d, vt = np.linalg.svd(cov)
    sign = np.eye(3)
    sign[2, 2] = np.sign(np.linalg.det(u @ vt))
    r = u @ sign @ vt
    var = (w * (a * a).sum(1)).sum()
    s = (d * np.diag(sign)).sum() / var
    return s, r, mu_d - s * r @ mu_s


class Fitter:
    def __init__(self, bank, corr, identity, expression):
        self.identity, self.expression = identity, expression
        self.keys = identity + expression
        self.p0 = sample(bank.base, corr)
        self.basis = np.stack([sample(bank.target(k), corr) for k in self.keys], -1)  # (478, 3, K)
        self.valid = corr["valid"].astype(bool)
        n_id = len(identity)
        self.lower = np.array([-2.0] * n_id + [0.0] * len(expression))
        self.upper = np.array([2.0] * n_id + [1.0] * len(expression))
        lo = [0.0 if k.startswith(("Race_", "Gender_", "Age_")) else -2.0 for k in identity]
        self.lower[:n_id] = lo
        self.ridge = np.array([RIDGE_IDENTITY] * n_id + [RIDGE_EXPRESSION] * len(expression))

    def fit(self, observed):
        """observed: (478, 3) in any frame (x right, y up, z towards the camera). -> weights, residual (m)."""
        w = np.zeros(len(self.keys))
        weight = self.valid.astype(np.float64)
        axis = np.array([1.0, 1.0, DEPTH_WEIGHT])
        for _ in range(ITERATIONS):
            model = self.p0 + self.basis @ w
            s, r, t = umeyama(model[self.valid], observed[self.valid], weight[self.valid])
            back = (observed - t) @ r / s  # the face in the model's frame
            rows = (self.basis[self.valid] * axis[None, :, None]).reshape(-1, len(self.keys))
            rhs = ((back - self.p0)[self.valid] * axis[None, :]).reshape(-1)
            scale = np.sqrt(len(rhs)) * 1e-3  # ridge in the same unit as a mm-sized landmark error
            a = np.vstack([rows, np.diag(np.sqrt(self.ridge)) * scale])
            b = np.concatenate([rhs, np.zeros(len(self.keys))])
            w = lsq_linear(a, b, bounds=(self.lower, self.upper), method="bvls").x
        model = self.p0 + self.basis @ w
        s, r, t = umeyama(model[self.valid], observed[self.valid], weight[self.valid])
        back = (observed - t) @ r / s
        residual = np.linalg.norm((back - model)[self.valid], axis=1)
        return w, residual, s


def observed_points(lm, aspect=1.0):
    """MediaPipe landmarks (x, y in 0..1, z like x) -> x right, y up, z towards the camera, in image widths."""
    return np.stack([lm[:, 0], -lm[:, 1] * aspect, -lm[:, 2]], 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bank")
    ap.add_argument("corr")
    ap.add_argument("landmarks")
    ap.add_argument("out")
    ap.add_argument("--catalogue", default="assets/_universe/characters/human/human_catalogue.json")
    ap.add_argument("--truth", action="store_true")
    args = ap.parse_args()
    bank = Bank(args.bank)
    corr = np.load(args.corr)
    identity, expression = face_keys(bank, args.catalogue)
    fitter = Fitter(bank, corr, identity, expression)
    marks = np.load(args.landmarks, allow_pickle=True)
    weights, residuals = [], []
    points = marks["points"]  # once: each marks["..."] reads the whole array again
    for k in range(len(points)):
        w, res, _s = fitter.fit(observed_points(points[k].astype(np.float64)))
        weights.append(w)
        residuals.append(res)
    weights, residuals = np.array(weights), np.array(residuals)
    rms = np.sqrt((residuals ** 2).mean(1)) * 1000
    print(f"{len(weights)} faces, {len(identity)} identity + {len(expression)} expression keys; "
          f"landmark residual {np.median(rms):.2f} mm median, {np.percentile(rms, 95):.2f} mm p95")
    np.savez_compressed(args.out, keys=np.array(fitter.keys), n_identity=len(identity), weights=weights,
                        residuals=residuals.astype(np.float32), paths=marks["paths"])
    if args.truth:
        score_against_truth(bank, fitter, marks, weights)


def score_against_truth(bank, fitter, marks, weights):
    """How well the creator's own faces are recovered: per key, and as face shapes."""
    n_id = len(fitter.identity)
    truth = np.zeros((len(weights), n_id))
    for k, path in enumerate(marks["paths"]):
        info = json.load(open(os.path.splitext(str(path))[0] + ".json"))
        for j, key in enumerate(fitter.identity):
            truth[k, j] = info["targets"].get(key, 0.0)
    fitted = weights[:, :n_id]
    corr = [np.corrcoef(truth[:, j], fitted[:, j])[0, 1] if truth[:, j].std() > 1e-6 else np.nan for j in range(n_id)]
    order = np.argsort(np.nan_to_num(corr, nan=-2))
    print("recovered per key (correlation truth / fit), worst first:")
    for j in order[:12]:
        print(f"  {fitter.identity[j]:40s} r = {corr[j]:+.2f}  truth sd {truth[:, j].std():.2f}")
    good = np.nanmedian(corr)
    print(f"median correlation {good:.2f}; keys with r > 0.7: {np.sum(np.array(corr) > 0.7)} of {np.sum(~np.isnan(corr))}")
    # As shapes: the face's vertices, true against fitted, after removing the similarity.
    targets = {key: bank.target(key) for key in fitter.identity}
    face = np.unique(np.concatenate([np.where(np.abs(targets[key]).sum(1) > 0)[0] for key in list(targets)[:5]]))
    errors = []
    for k in range(len(weights)):
        a = bank.base[face] + sum(truth[k, j] * targets[key][face] for j, key in enumerate(fitter.identity))
        b = bank.base[face] + sum(fitted[k, j] * targets[key][face] for j, key in enumerate(fitter.identity))
        errors.append(np.sqrt(((a - b) ** 2).sum(1).mean()) * 1000)
    base_err = [np.sqrt(((sum(truth[k, j] * targets[key][face] for j, key in enumerate(fitter.identity))) ** 2).sum(1).mean()) * 1000
                for k in range(len(weights))]
    print(f"face shape error: {np.median(errors):.2f} mm median (the neutral face would be {np.median(base_err):.2f} mm off)")


if __name__ == "__main__":
    sys.exit(main())
