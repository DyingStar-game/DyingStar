#!/usr/bin/env python3
"""From MediaPipe's landmarks to a face shape our creator understands -- learnt on our own renders.

MediaPipe's 478 landmarks follow a face's features only loosely: their error on our own rendered faces is
about as large as the difference between two faces (fit.py --truth). So the mapping is learnt where the
answer is known: thousands of random faces rendered by render_heads.tscn (--random), each with its true
shape. A ridge regression goes from the landmarks (pose and scale removed) to the principal components of
the face's dense shape; the creator's sliders are then fitted to that dense shape, which -- unlike the
landmarks -- tells them apart.

    python3 regress.py train <human_bank.npz> <synthetic landmarks.npz> <model.npz>
    python3 regress.py train-views <human_bank.npz> <model.npz> <front.npz> <turned.npz>...
    python3 regress.py apply <human_bank.npz> <model.npz> <landmarks.npz> <out.npz> [--report]

train-views learns from the same faces seen from several sides (render_heads.tscn --random --seed=S --yaw=Y, the
same S each time): one regression per set of views (the front, with one turned view a side at most), each view's
landmarks aligned on that view's own mean -- what the game's FaceFit uses (pack_face_fit.tscn --model=). On FLAME
faces: the front alone 1.80 mm, with a side at 40 degrees 1.25 mm, with both 1.09 mm (the mean face 2.97 mm).

apply writes, per face: the predicted shape's components, the slider weights that best make it, and what
the sliders could not make (the residual shape, per vertex) -- what the creator lacks.
"""
import argparse
import itertools
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fit import Bank, face_keys  # noqa: E402

CATALOGUE = "assets/_universe/characters/human/human_catalogue.json"
FACE_VERTICES = 2500  # vertices of the face the shape is described by (evenly picked)
COMPONENTS = 60
HOLDOUT = 0.15
MIN_FACES = 500  # a set of views MediaPipe found on fewer faces is not learnt (two profiles: 185 faces, no better)
SEED = 1


def face_vertex_set(bank):
    """Compact vertices of the face's front: in front of the ears, from the neck to the forehead."""
    b = np.load(bank.path, allow_pickle=True)
    names = [str(z) for z in b["zone_names"]]
    z = names.index("Face")
    ids = np.unique(b["body_vertex"][b["zone_vertex_ptr"][z]:b["zone_vertex_ptr"][z + 1]])
    p = bank.base[ids]
    front = ids[(p[:, 2] > 0.0) & (p[:, 1] > 1.48) & (p[:, 1] < 1.72) & (np.abs(p[:, 0]) < 0.075)]
    rng = np.random.default_rng(SEED)
    return np.sort(rng.choice(front, size=min(FACE_VERTICES, len(front)), replace=False))


def procrustes(points, reference, weights=None):
    """points aligned on reference by a similarity (rows are points)."""
    w = np.ones(len(points)) if weights is None else weights
    w = w / w.sum()
    mp, mr = (points * w[:, None]).sum(0), (reference * w[:, None]).sum(0)
    a, b = points - mp, reference - mr
    u, d, vt = np.linalg.svd((b * w[:, None]).T @ a)
    sign = np.eye(3)
    sign[2, 2] = np.sign(np.linalg.det(u @ vt))
    r = u @ sign @ vt
    s = (d * np.diag(sign)).sum() / (w * (a * a).sum(1)).sum()
    return (s * (r @ a.T)).T + mr


def landmark_features(points, mean_landmarks=None):
    """MediaPipe landmarks (n, 478, 3), x right, y down, z away -> pose- and scale-free, flattened."""
    out = []
    p = np.stack([points[..., 0], -points[..., 1], -points[..., 2]], -1)
    ref = p[0] if mean_landmarks is None else mean_landmarks
    for _ in range(2 if mean_landmarks is None else 1):
        aligned = np.array([procrustes(q, ref) for q in p])
        ref = aligned.mean(0)
    if mean_landmarks is not None:
        aligned = np.array([procrustes(q, mean_landmarks) for q in p])
    return aligned.reshape(len(p), -1), ref


class Shapes:
    """True dense face shapes of rendered faces, from their JSON (render_heads.tscn)."""

    def __init__(self, bank, vertices):
        self.bank, self.vertices, self.cache = bank, vertices, {}

    def of(self, targets, stature):
        pts = self.bank.base[self.vertices].copy()
        for key, w in targets.items():
            if key not in self.cache:
                self.cache[key] = self.bank.target(key)[self.vertices]
            pts += w * self.cache[key]
        return pts * stature


def train(args):
    bank = Bank(args.bank)
    bank.path = args.bank
    vertices = face_vertex_set(bank)
    marks = np.load(args.landmarks, allow_pickle=True)
    shapes_of = Shapes(bank, vertices)
    truth = []
    for path in marks["paths"]:
        info = json.load(open(os.path.splitext(str(path))[0] + ".json"))
        truth.append(shapes_of.of(info["targets"], info["stature"]))
    truth = np.array(truth)
    mean_shape = truth.mean(0)
    truth = np.array([procrustes(t, mean_shape) for t in truth])
    mean_shape = truth.mean(0)
    x, mean_landmarks = landmark_features(marks["points"].astype(np.float64))
    y = (truth - mean_shape).reshape(len(truth), -1)
    # Principal components of the true shapes.
    u, s, vt = np.linalg.svd(y, full_matrices=False)
    comps = vt[:COMPONENTS]
    explained = (s[:COMPONENTS] ** 2).sum() / (s ** 2).sum()
    coeffs = y @ comps.T
    rng = np.random.default_rng(SEED)
    order = rng.permutation(len(x))
    n_test = int(len(x) * HOLDOUT)
    test, fit_rows = order[:n_test], order[n_test:]
    x_mean, x_std = x[fit_rows].mean(0), x[fit_rows].std(0) + 1e-9
    xs = (x - x_mean) / x_std
    best = None
    for alpha in (0.03, 0.1, 0.3, 1.0, 10.0, 100.0):
        a = xs[fit_rows]
        beta = np.linalg.solve(a.T @ a + alpha * np.eye(a.shape[1]), a.T @ coeffs[fit_rows])
        pred = xs[test] @ beta
        err = shape_error(pred, coeffs[test], comps)
        print(f"alpha {alpha:8.2f}: held-out shape error {np.median(err) * 1000:.2f} mm median")
        if best is None or np.median(err) < best[0]:
            best = (np.median(err), alpha, beta)
    base = shape_error(np.zeros_like(coeffs[test]), coeffs[test], comps)
    # A ridge regression pulls its answers towards the mean: per component, how much wider the true shapes
    # spread than the predicted ones (apply --deshrink widens them back, for distributions, not single faces).
    pred = xs[test] @ best[2]
    deshrink = coeffs[test].std(0) / np.maximum(pred.std(0), 1e-12)
    print(f"spread lost to the regression: x{np.median(deshrink):.2f} median over the components")
    print(f"{len(x)} renders, {len(vertices)} face vertices, {COMPONENTS} components ({explained * 100:.1f} % of the variance); "
          f"best alpha {best[1]:.2f}: {best[0] * 1000:.2f} mm against {np.median(base) * 1000:.2f} mm for the mean face")
    np.savez_compressed(args.model, vertices=vertices, mean_shape=mean_shape, components=comps, beta=best[2],
                        x_mean=x_mean, x_std=x_std, mean_landmarks=mean_landmarks, test=test, deshrink=deshrink)


def train_views(args):
    """Joint regressions over views of the same faces (paired by file name), one per set of views holding the front,
    each learnt on the faces MediaPipe found in all of its views (it misses many beyond 80 degrees)."""
    bank = Bank(args.bank)
    bank.path = args.bank
    vertices = face_vertex_set(bank)
    shapes_of = Shapes(bank, vertices)
    views = []
    for path in args.views:
        z = np.load(path, allow_pickle=True)
        views.append({os.path.basename(str(p)): (str(p), pts) for p, pts in zip(z["paths"], z["points"])})
    heads = sorted(views[0])
    truth = []
    for h in heads:
        info = json.load(open(os.path.splitext(views[0][h][0])[0] + ".json"))
        truth.append(shapes_of.of(info["targets"], info["stature"]))
    truth = np.array(truth)
    mean_shape = truth.mean(0)
    truth = np.array([procrustes(t, mean_shape) for t in truth])
    mean_shape = truth.mean(0)
    y = (truth - mean_shape).reshape(len(truth), -1)
    _, s, vt = np.linalg.svd(y, full_matrices=False)
    comps = vt[:COMPONENTS]
    coeffs = y @ comps.T
    feats, refs, turns, present = [], [], [], []
    for v in views:
        seen = np.array([h in v for h in heads])
        points = np.array([v[h][1] for h in heads if h in v]).astype(np.float64)
        x, ref = landmark_features(points)
        full = np.full((len(heads), x.shape[1]), np.nan)
        full[seen] = x
        feats.append(full)
        present.append(seen)
        refs.append(ref)
        # How the view's faces turn in the image (FaceFit.turn): the nose's tip (1) off the cheeks' middle, over
        # their span, > 0 to the right; the front (the first) 0.
        offset = np.median((points[:, 1, 0] - 0.5 * (points[:, 234, 0] + points[:, 454, 0]))
                           / np.abs(points[:, 454, 0] - points[:, 234, 0]))
        turns.append(float(offset) if turns else 0.0)
    rng = np.random.default_rng(SEED)
    order = rng.permutation(len(heads))
    n_test = int(len(heads) * HOLDOUT)
    test, rest = order[:n_test], order[n_test:]
    check, fit_rows = rest[:n_test], rest[n_test:]  # the ridge's strength chosen on these, the test kept clean
    out = {"vertices": vertices, "mean_shape": mean_shape, "components": comps, "mean_landmarks": np.array(refs),
           "coeff_std": coeffs[fit_rows].std(0),
           "view_turn": np.array(turns, dtype=np.float32), "test": test, "heads": np.array(heads)}
    masks = []
    for n in range(len(views)):
        for subset in itertools.combinations(range(1, len(views)), n):
            if len({np.sign(turns[i]) for i in subset}) < len(subset):
                continue  # one photo a side
            idx = (0,) + subset
            mask = sum(1 << i for i in idx)
            seen = np.all([present[i] for i in idx], 0)
            if seen.sum() < MIN_FACES:
                print(f"views {[os.path.basename(args.views[i]) for i in idx]}: only {seen.sum()} faces, left out")
                continue
            f_rows, c_rows, r_rows, t_rows = (r[seen[r]] for r in (fit_rows, check, rest, test))
            x = np.concatenate([feats[i] for i in idx], 1)
            x_mean, x_std = x[f_rows].mean(0), x[f_rows].std(0) + 1e-9
            xs = (x - x_mean) / x_std
            best = None
            for alpha in (0.3, 1.0, 3.0, 10.0, 30.0, 100.0):
                a = xs[f_rows]
                beta = np.linalg.solve(a.T @ a + alpha * np.eye(a.shape[1]), a.T @ coeffs[f_rows])
                err = np.median(shape_error(xs[c_rows] @ beta, coeffs[c_rows], comps))
                if best is None or err < best[0]:
                    best = (err, alpha)
            a = xs[r_rows]
            beta = np.linalg.solve(a.T @ a + best[1] * np.eye(a.shape[1]), a.T @ coeffs[r_rows])
            err = np.median(shape_error(xs[t_rows] @ beta, coeffs[t_rows], comps))
            if mask == 1:
                out.update({"beta_1": beta, "x_mean_1": x_mean, "x_std_1": x_std})
            front = np.median(shape_error(((feats[0][t_rows] - out["x_mean_1"]) / out["x_std_1"]) @ out["beta_1"],
                                          coeffs[t_rows], comps))
            print(f"views {[os.path.basename(args.views[i]) for i in idx]}: {len(r_rows)} faces, alpha {best[1]:.1f}, "
                  f"held-out {err * 1000:.2f} mm median (on its {len(t_rows)} test faces; the front alone {front * 1000:.2f} mm)")
            out.update({f"beta_{mask}": beta, f"x_mean_{mask}": x_mean, f"x_std_{mask}": x_std, f"error_{mask}": np.float32(err)})
            masks.append(mask)
    base = np.median(shape_error(np.zeros_like(coeffs[test]), coeffs[test], comps))
    print(f"{len(heads)} faces, view turns {np.round(turns, 2)}; the mean face {base * 1000:.2f} mm")
    out["masks"] = np.array(masks, dtype=np.int32)
    np.savez_compressed(args.model, **out)


def shape_error(pred, truth, comps):
    """Per face: rms over the face vertices of the shape difference (m)."""
    diff = (pred - truth) @ comps
    return np.sqrt((diff.reshape(len(diff), -1, 3) ** 2).sum(-1).mean(-1))


def apply(args):
    bank = Bank(args.bank)
    bank.path = args.bank
    model = np.load(args.model)
    vertices, comps = model["vertices"], model["components"]
    marks = np.load(args.landmarks, allow_pickle=True)
    rows = np.load(args.mask) if args.mask else np.ones(len(marks["paths"]), dtype=bool)
    x, _ = landmark_features(marks["points"][rows].astype(np.float64), model["mean_landmarks"])
    coeffs = ((x - model["x_mean"]) / model["x_std"]) @ model["beta"]
    if args.deshrink:
        coeffs = coeffs * model["deshrink"][None]
    shapes = model["mean_shape"][None] + (coeffs @ comps).reshape(len(coeffs), -1, 3)
    identity, _expression = face_keys(bank, CATALOGUE)
    if args.keyset == "flame":  # the face as FLAME's identity directions, with gender and age
        identity = [k for k in bank.names if k.startswith("FLAME_Identity_")] + ["Gender_Female", "Gender_Male", "Age_Old"]
    basis = np.stack([bank.target(k)[vertices] for k in identity], -1)  # (V, 3, K)
    base = bank.base[vertices]
    lower = np.array([0.0 if k.startswith(("Race_", "Gender_", "Age_")) else -3.0 for k in identity])
    prior = np.array([1.0 if k.startswith("FLAME_") else 0.05 for k in identity])  # FLAME's are N(0, 1)
    upper = np.full(len(identity), 3.0)
    weights, residual = [], []
    a = basis.reshape(-1, len(identity))
    ridge = np.diag(prior) * (args.prior if args.keyset == "flame" else 1.0) * 4e-6
    solve = np.linalg.solve(a.T @ a + ridge, a.T)  # ridge, the same for every face
    for shape in shapes:
        w = np.zeros(len(identity))
        for _ in range(3):  # the similarity, then the weights, twice over
            target = procrustes(shape, base + basis @ w)
            w = np.clip(solve @ (target - base).reshape(-1), lower, upper)
        made = base + basis @ w
        weights.append(w)
        residual.append((procrustes(shape, made) - made).astype(np.float32))
    weights, residual = np.array(weights), np.array(residual)
    marks = {"paths": marks["paths"][rows]}
    rms = np.sqrt((residual ** 2).sum(-1).mean(-1)) * 1000
    print(f"{len(weights)} faces: what the sliders cannot make, {np.median(rms):.2f} mm median, {np.percentile(rms, 95):.2f} mm p95")
    np.savez_compressed(args.out, keys=np.array(identity), weights=weights, residual=residual, coeffs=coeffs,
                        vertices=vertices, paths=marks["paths"])
    if args.report:
        report_truth(bank, identity, marks, weights)


def report_truth(bank, identity, marks, weights):
    truth = np.zeros_like(weights)
    for k, path in enumerate(marks["paths"]):
        info = json.load(open(os.path.splitext(str(path))[0] + ".json"))
        truth[k] = [info["targets"].get(key, 0.0) for key in identity]
    corr = [np.corrcoef(truth[:, j], weights[:, j])[0, 1] for j in range(len(identity)) if truth[:, j].std() > 1e-6]
    print(f"sliders recovered: median correlation {np.nanmedian(corr):.2f}, {np.sum(np.array(corr) > 0.7)} of {len(corr)} above 0.7")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("train")
    t.add_argument("bank")
    t.add_argument("landmarks")
    t.add_argument("model")
    v = sub.add_parser("train-views")
    v.add_argument("bank")
    v.add_argument("model")
    v.add_argument("views", nargs="+", help="landmarks of the same faces: the front first, then the turned ones")
    a = sub.add_parser("apply")
    a.add_argument("bank")
    a.add_argument("model")
    a.add_argument("landmarks")
    a.add_argument("out")
    a.add_argument("--report", action="store_true")
    a.add_argument("--mask", help="a boolean .npy: which faces of the landmarks file to take")
    a.add_argument("--deshrink", action="store_true", help="widen the predictions back to the true spread")
    a.add_argument("--keyset", choices=("catalogue", "flame"), default="catalogue",
                   help="fit the predicted shape with the creator's sliders, or FLAME's directions (+ gender, age)")
    a.add_argument("--prior", type=float, default=1.0, help="strength of FLAME's N(0, 1) law against the shape")
    args = ap.parse_args()
    {"train": train, "train-views": train_views, "apply": apply}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
