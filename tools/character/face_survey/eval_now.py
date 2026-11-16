#!/usr/bin/env python3
"""The photo-to-character's faces against the NoW benchmark's scans (eval_now.tscn's model and fits), following
its evaluation (github.com/soubhiksanyal/now_evaluation) without its MPI libraries: the scan cropped about the face's
centre from its 7 landmarks, our face aligned on them, then rigidly onto the scan (ICP), and every scan vertex's
distance to our surface. "metrical": rotation and translation only, so the face's size counts (ours is the body's
true size); "nonmetrical": a scale too (the benchmark's first protocol).

Also the sliders' own limit ("oracle"): the creator's shape sliders fitted straight to each scan -- what no photo
reading can beat; if it is far from 0, the sliders lack what real faces have.

    python3 eval_now.py --now ~/datasets/now --fits <dir>   (dir: eval_now.tscn's model_*.json/.f32 and fits.json)
"""
import argparse
import json
import os
import sys

import numpy as np
from scipy.optimize import lsq_linear
from scipy.spatial import cKDTree

BASES = ("default_male", "default_female")


def load_model(stem):
    info = json.load(open(stem + ".json"))
    v = info["vertices"]
    blob = np.fromfile(stem + ".f32", dtype=np.float32).reshape(-1, v, 3).astype(np.float64) * 1000.0  # mm
    return {"base": blob[0], "deltas": blob[1:], "tri": np.array(info["triangles"]).reshape(-1, 3), "keys": info["keys"],
            "lmk": info["landmarks"], "ranges": np.array(info["ranges"])}


def mesh_of(model, weights):
    w = np.array([weights.get(k, 0.0) for k in model["keys"]])
    return model["base"] + np.einsum("k,kvc->vc", w, model["deltas"])


def landmarks_of(model, v):
    return np.array([sum(v[i] * b for i, b in corner) for corner in model["lmk"]])


def load_obj(path):
    vs, fs = [], []
    for line in open(path):
        if line.startswith("v "):
            vs.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("f "):
            fs.append([int(x.split("/")[0]) - 1 for x in line.split()[1:4]])
    return np.array(vs), np.array(fs)


def load_pp(path):
    out = []
    for line in open(path):
        if "<point" in line:
            attrs = dict(part.split("=", 1) for part in line.replace("/>", "").split() if "=" in part)
            out.append([float(attrs[c].strip('"')) for c in "xyz"])
    return np.array(out[:7])


def crop(scan_v, lmk):
    nose_bottom = lmk[4]
    bridge = 0.5 * (lmk[1] + lmk[2])
    centre = nose_bottom + 0.3 * (bridge - nose_bottom)
    radius = 1.4 * (np.linalg.norm(lmk[0] - lmk[3]) + np.linalg.norm(bridge - nose_bottom)) / 2
    return scan_v[np.linalg.norm(scan_v - centre, axis=1) <= radius]


def similarity(src, dst, scale):
    """R, s, t taking src onto dst (least squares; Umeyama), s = 1 without scale."""
    ms, md = src.mean(0), dst.mean(0)
    a, b = src - ms, dst - md
    u, sig, vt = np.linalg.svd(b.T @ a)
    d = np.sign(np.linalg.det(u @ vt))
    fix = np.diag([1.0, 1.0, d])
    r = u @ fix @ vt
    s = (sig * np.diag(fix)).sum() / (a ** 2).sum() if scale else 1.0
    return r, s, md - s * r @ ms


def closest_on_mesh(points, v, tri, tree=None, k=12):
    """Per point: its nearest point on the mesh, the triangle and barycentrics (searching the k nearest triangles)."""
    centroids = v[tri].mean(1)
    tree = cKDTree(centroids)
    _, cand = tree.query(points, k=k)
    a, b, c = v[tri[cand, 0]], v[tri[cand, 1]], v[tri[cand, 2]]
    p = points[:, None, :]
    q, bary = _closest_on_triangles(p, a, b, c)
    d = np.linalg.norm(q - p, axis=2)
    best = d.argmin(1)
    rows = np.arange(len(points))
    return q[rows, best], cand[rows, best], bary[rows, best], d[rows, best]


def _closest_on_triangles(p, a, b, c):
    """Ericson's closest point on triangle, vectorised; returns the points and their barycentrics (u, v, w)."""
    ab, ac, ap = b - a, c - a, p - a
    d1, d2 = (ab * ap).sum(-1), (ac * ap).sum(-1)
    bp = p - b
    d3, d4 = (ab * bp).sum(-1), (ac * bp).sum(-1)
    cp = p - c
    d5, d6 = (ab * cp).sum(-1), (ac * cp).sum(-1)
    va = d3 * d6 - d5 * d4
    vb = d5 * d2 - d1 * d6
    vc = d1 * d4 - d3 * d2
    eps = 1e-12
    denom = 1.0 / np.maximum(va + vb + vc, eps)
    v = vb * denom
    w = vc * denom
    u = 1 - v - w
    bary = np.stack([u, v, w], -1)
    # regions
    def setb(mask, uu, vv, ww):
        bary[mask] = np.stack([uu[mask], vv[mask], ww[mask]], -1)
    one, zero = np.ones_like(d1), np.zeros_like(d1)
    vab = d1 / np.where(np.abs(d1 - d3) > eps, d1 - d3, eps)
    vac = d2 / np.where(np.abs(d2 - d6) > eps, d2 - d6, eps)
    wbc = (d4 - d3) / np.where(np.abs((d4 - d3) + (d5 - d6)) > eps, (d4 - d3) + (d5 - d6), eps)
    m_bc = (va <= 0) & ((d4 - d3) >= 0) & ((d5 - d6) >= 0)
    setb(m_bc, zero, 1 - wbc, wbc)
    m_ac = (vb <= 0) & (d2 >= 0) & (d6 <= 0)
    setb(m_ac, 1 - vac, zero, vac)
    m_ab = (vc <= 0) & (d1 >= 0) & (d3 <= 0)
    setb(m_ab, 1 - vab, vab, zero)
    m_c = (d6 >= 0) & (d5 <= d6)
    setb(m_c, zero, zero, one)
    m_b = (d3 >= 0) & (d4 <= d3)
    setb(m_b, zero, one, zero)
    m_a = (d1 <= 0) & (d2 <= 0)
    setb(m_a, one, zero, zero)
    q = bary[..., 0:1] * a + bary[..., 1:2] * b + bary[..., 2:3] * c
    return q, bary


def align(scan, scan_lmk, v, model, scale, iterations=15):
    """Our mesh's vertices v moved onto the scan: by the 7 landmarks (either side order), then rigid ICP (on a third
    of the scan's points: as good, three times quicker)."""
    scan = scan[::3]
    ours = landmarks_of(model, v)
    best = None
    for order in ([0, 1, 2, 3, 4, 5, 6], [3, 2, 1, 0, 4, 6, 5]):
        r, s, t = similarity(ours[order], scan_lmk, scale)
        err = np.linalg.norm((s * (r @ ours[order].T)).T + t - scan_lmk, axis=1).mean()
        if best is None or err < best[0]:
            best = (err, r, s, t)
    _, r, s, t = best
    v = (s * (r @ v.T)).T + t
    for _ in range(iterations):
        q, _, _, _ = closest_on_mesh(scan, v, model["tri"])
        r, s, t = similarity(q, scan, scale)  # move the mesh's matched points onto the scan
        v = (s * (r @ v.T)).T + t
    return v


def scan_error(scan, v, model):
    return closest_on_mesh(scan, v, model["tri"])[3]


def oracle(scan, scan_lmk, model, scale, rounds=8, ridge=1e-3):
    """The shape sliders fitted straight to the scan (bounded by their ranges), alternating with the alignment."""
    weights = {}
    lo, hi = -model["ranges"], model["ranges"]
    full = scan
    scan = scan[::3]
    v = align(scan, scan_lmk, mesh_of(model, weights), model, scale)
    k = len(model["keys"])
    for _ in range(rounds):
        # Pose of the current mesh relative to the model frame: refit it from the aligned mesh.
        raw = mesh_of(model, weights)
        r, s, t = similarity(raw, v, True if scale else False)
        q, tri_i, bary, _ = closest_on_mesh(scan, v, model["tri"])
        idx = model["tri"][tri_i]  # (n, 3)
        # Each scan point p ~ s R (sum_b b (base + D w)) + t: linear in w.
        base_pts = np.einsum("nj,njc->nc", bary, model["base"][idx])
        d = np.einsum("nj,knjc->nkc", bary, model["deltas"][:, idx])  # (n, k, 3)
        a = s * np.einsum("cd,nkd->nck", r, d).reshape(-1, k)
        b = (scan - (s * (r @ base_pts.T)).T - t).reshape(-1)
        a = np.vstack([a, np.sqrt(ridge * len(scan)) * np.eye(k)])
        b = np.concatenate([b, np.zeros(k)])
        sol = lsq_linear(a, b, bounds=(lo, hi), lsmr_tol="auto", max_iter=200).x
        weights = dict(zip(model["keys"], sol))
        v = align(full, scan_lmk, mesh_of(model, weights), model, scale, iterations=8)
    return v, weights


def summary(name, distances):
    d = np.concatenate(distances) if distances else np.array([np.nan])
    return f"{name:34s} median {np.median(d):.3f} mean {np.mean(d):.3f} std {np.std(d):.3f} mm"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--now", default=os.path.expanduser("~/datasets/now"))
    ap.add_argument("--fits", required=True)
    ap.add_argument("--protocol", default="metrical", choices=("metrical", "nonmetrical"))
    ap.add_argument("--single", action="store_true", help="also every validation photo alone (the official protocol)")
    args = ap.parse_args()
    scale = args.protocol == "nonmetrical"
    models = {b: load_model(os.path.join(args.fits, "model_" + b)) for b in BASES}
    fits = json.load(open(os.path.join(args.fits, "fits.json")))
    people = sorted(next(iter(fits["sets"].values())).keys())
    results = {}
    chosen = {}
    for person in people:
        scan_dir = os.path.join(args.now, "scans", person)
        obj = [f for f in os.listdir(scan_dir) if f.endswith(".obj")][0]
        scan_v, _ = load_obj(os.path.join(scan_dir, obj))
        lmk = load_pp(os.path.join(args.now, "scans_lmks_onlypp", person, obj.replace(".obj", "_picked_points.pp")))
        scan = crop(scan_v, lmk)
        line = [person[-8:]]
        per_base = {}
        for base in BASES:
            m = models[base]
            ov, _ = oracle(scan, lmk, m, scale)
            per_base[base] = {"oracle": scan_error(scan, ov, m)}
            per_base[base]["base face"] = scan_error(scan, align(scan, lmk, m["base"], m, scale), m)
            for cond in ("front_only", "front_left", "front_right", "front_both"):
                w = fits["sets"][base][person].get(cond)
                if w is not None:
                    per_base[base][cond] = scan_error(scan, align(scan, lmk, mesh_of(m, w), m, scale), m)
        # The player tells their sex: the base whose sliders fit the scan best.
        base = min(BASES, key=lambda b: np.mean(per_base[b]["oracle"]))
        chosen[person] = base
        for cond, d in per_base[base].items():
            results.setdefault(cond, []).append(d)
            line.append(f"{cond} {np.mean(d):.2f}")
        print(" | ".join(line) + f" ({base[8:]})", flush=True)
    print(f"\n{args.protocol}, {len(people)} people, each on the base of their sex (by the sliders' best fit):")
    for cond in ("oracle", "base face", "front_only", "front_left", "front_right", "front_both"):
        if cond in results:
            print(summary(f"{cond} ({len(results[cond])})", results[cond]))
    if args.single:
        by_kind = {}
        for path, w in fits["single"][BASES[0]].items():
            person = path.split("/")[0]
            base = chosen.get(person, BASES[0])
            w = fits["single"][base][path]
            m = models[base]
            scan_dir = os.path.join(args.now, "scans", person)
            obj = [f for f in os.listdir(scan_dir) if f.endswith(".obj")][0]
            scan_v, _ = load_obj(os.path.join(scan_dir, obj))
            lmk = load_pp(os.path.join(args.now, "scans_lmks_onlypp", person, obj.replace(".obj", "_picked_points.pp")))
            scan = crop(scan_v, lmk)
            d = scan_error(scan, align(scan, lmk, mesh_of(m, w), m, scale), m)
            by_kind.setdefault(path.split("/")[1], []).append(d)
            by_kind.setdefault("all", []).append(d)
        print("\nOne photo, one face (the benchmark's protocol), by kind of photo:")
        for kind, ds in sorted(by_kind.items()):
            print(summary(f"{kind} ({len(ds)})", ds))


if __name__ == "__main__":
    sys.exit(main())
