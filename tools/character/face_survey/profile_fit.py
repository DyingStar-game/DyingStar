#!/usr/bin/env python3
"""The photo-to-character's profile fit, prototyped and judged on NoW: a true profile photo's outline
(PhotoProfile.measure, dump_landmarks.tscn --profile) moves the nose sliders so that our head's outline seen from the
side follows it -- the dip at the nose's root, the bridge, the tip -- the rest of the face held as the front made it.

Our outline: the face's vertices near the middle (|x| < BAND mm), seen from the side, each height's furthest out.
The photo's outline is laid on ours by a 2D similarity (scale, tilt, shift: from the nose's tip and the face's
height, then nearest points), then the sliders solved for the outline's horizontal gaps between the eyes and the
mouth (Gauss-Newton on the vertex furthest out at each height), with a ridge to where the front put them.

    python3 profile_fit.py --models <eval_now dir> [--ridges 1,3,10]
"""
import argparse, json, os, re, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "ava"))
import eval_now as e
import ava_profile as P

NOW = os.path.expanduser("~/datasets/now")
BAND = 12.0  # mm either side of the face's middle
BIN = 0.5  # mm: the outline's height steps
NOSE_KEYS = ["Nose_NasalBone", "Nose_NasalBone_AnteriorNasalAperature", "Nose_NasalBone_AnteriorNasalSpine", "Nose_Potrusion",
             "Nose_NasalAngle", "Nose_NostrilSize", "Nose_Tip_Potrusion", "Nose_BottomFlatness", "Nose_BridgeProminence",
             "Nose_NoseHeight"]


def mp_points(model, v):
    return np.array([sum(v[i] * b for i, b in corner) for corner in model["mp"]])


BARY = np.array([[a, b, 1 - a - b] for a in np.linspace(0, 1, 5) for b in np.linspace(0, 1, 5) if a + b <= 1.0 + 1e-9])


def surface(v, model):
    """Points on our face's surface (every triangle sampled), and their (triangle, barycentric) for the slopes."""
    tri = model["tri"]
    pts = np.einsum("sj,tjc->tsc", BARY, v[tri]).reshape(-1, 3)
    return pts


def envelope(v, model, lo, hi, h=(0.0, 1.0)):
    """Our outline between heights lo and hi (mm) as a camera sees it whose image's horizontal is h (x, z: (0, 1)
    straight from the side): per BIN step, the furthest-out vertex along h (its index, or -1). Returns (heights,
    furthest, vertex)."""
    pts = surface(v, model)
    far = pts[:, 0] * h[0] + pts[:, 2] * h[1]
    ys = np.arange(lo, hi, BIN)
    z = np.full(len(ys), np.nan)
    idx = np.full(len(ys), -1)
    bins = np.floor((pts[:, 1] - lo) / BIN).astype(int)
    ok = np.where((bins >= 0) & (bins < len(ys)))[0]
    order = ok[np.lexsort((far[ok], bins[ok]))]  # by bin, then furthest last
    last = np.r_[bins[order][1:] != bins[order][:-1], True]
    top = order[last]
    z[bins[top]], idx[bins[top]] = far[top], top
    return ys + 0.5 * BIN, z, idx


TRIM = 0.8  # the share of the photo's outline points (nearest ours) each laying step follows
STARTS = (0.7, 0.9, 1.1, 1.3)  # the photo's scale tried first: our face's height (mm) per detector box height
FILL = 2  # height steps either side an outline step takes its furthest from (the forehead's large triangles leave dents)
VIEWS = np.radians(np.arange(-25, 11, 5))  # the photo's view off a pure profile (75 to 100 degrees)


def nose_span(v, model):
    """Our nose's heights (mm, y up): from its root (landmark 168) to its base (2), a little inside both."""
    mp = mp_points(model, v)
    return mp[2, 1] + 2.0, mp[168, 1] - 3.0


def similarity2(src, dst):
    """2D similarity src -> dst, Horn's symmetric scale (nearest points on a curve pull no collapse)."""
    ms, md = src.mean(0), dst.mean(0)
    a, b = src - ms, dst - md
    u, _, vt = np.linalg.svd(b.T @ a)
    r = u @ np.diag([1, np.sign(np.linalg.det(u @ vt))]) @ vt
    sc = np.sqrt((b ** 2).sum() / max((a ** 2).sum(), 1e-12))
    return lambda x: sc * ((x - ms) @ r.T) + md


def lay(photo, v, model):
    """The photo's outline in our head's side view (forward, up; mm), laid on ours by its forehead, lips and chin
    (trimmed ICP, the nose left out: it is what is fitted), the best of a few starting scales and views:
    (points, view direction h, our nose's span)."""
    from scipy.spatial import cKDTree
    run = P.clean(photo["profile"])  # face heights from the tip: forward, down
    if run is None:
        return None
    uv = np.stack([run[:, 0], -run[:, 1]], 1)
    mp = mp_points(model, v)
    height = np.linalg.norm(mp[10] - mp[152])
    lo, hi = nose_span(v, model)
    best = None
    for delta in VIEWS:
        h = (np.sin(delta), np.cos(delta))
        ys, z, _ = envelope(v, model, mp[152, 1] - 0.15 * height, mp[10, 1] + 0.02 * height, h)
        z = np.nanmax(np.stack([np.roll(z, k) for k in range(-FILL, FILL + 1)]), 0)
        good = np.isfinite(z)
        ours = np.stack([z[good], ys[good]], 1)
        anchor = (ours[:, 1] < lo - 4.0) | (ours[:, 1] > hi + 4.0)
        tree = cKDTree(ours[anchor])
        band = (ours[:, 1] > lo) & (ours[:, 1] < hi)
        tip = ours[band][np.argmax(ours[band][:, 0])]
        for start in STARTS:
            q = uv * start * height + tip
            lowest, highest = ours[:, 1].min() - 1.0, ours[:, 1].max() + 1.0
            for _ in range(30):
                d, j = tree.query(q)
                inside = (q[:, 1] > lowest) & (q[:, 1] < highest)  # the photo's neck, top of head: nothing to match
                keep = inside & (d <= np.quantile(d[inside], TRIM))
                q = similarity2(q[keep], ours[anchor][j[keep]])(q)
            d, _ = tree.query(q)
            inside = (q[:, 1] > lowest) & (q[:, 1] < highest)
            score = np.mean(np.sort(d[inside])[: int(TRIM * inside.sum())] ** 2)
            if best is None or score < best[0]:
                best = (score, q, h)
    return best[1], best[2], (lo, hi)


def fit(profile, model, w0, keys, ridge, rounds=5):
    w = dict(w0)
    free = [k for k in keys if k in model["keys"]]
    order = [model["keys"].index(k) for k in free]
    for _ in range(rounds):
        v = e.mesh_of(model, w)
        laid = lay(profile, v, model)
        if laid is None:
            return w
        q, h, (lo, hi) = laid
        sel = (q[:, 1] < hi + 4.0) & (q[:, 1] > lo - 2.0)  # the nose: from its root to its base
        ys, z, idx = envelope(v, model, q[sel, 1].min() - BIN, q[sel, 1].max() + BIN, h)
        b = np.clip(np.floor((q[sel, 1] - (ys[0] - 0.5 * BIN)) / BIN).astype(int), 0, len(ys) - 1)
        good = idx[b] >= 0
        rows = idx[b][good]
        resid = q[sel][good, 0] - z[b][good]  # how much further out the photo's outline is
        tri = model["tri"][rows // len(BARY)]  # the samples' triangles and weights
        bw = BARY[rows % len(BARY)]
        d = model["deltas"][order]  # (k, v, 3)
        along = d[:, :, 0] * h[0] + d[:, :, 2] * h[1]  # (k, v)
        jac = np.einsum("nj,knj->nk", bw, along[:, tri])  # d far / d w
        cur = np.array([w.get(k, 0.0) for k in free])
        prior = np.array([w0.get(k, 0.0) for k in free])
        a = jac.T @ jac + ridge * len(rows) * np.eye(len(free))
        rhs = jac.T @ resid + ridge * len(rows) * (prior - cur)
        step = np.linalg.solve(a, rhs)
        rng = model["ranges"][order]
        for k, x in zip(free, np.clip(cur + step, -rng, rng)):
            w[k] = float(x)
    return w


def plot(folder, person, photo, m, w0, w1):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(5, 7))
    for w, colour, name in ((w0, "b", "front"), (w1, "g", "profile fit")):
        v = e.mesh_of(m, w)
        q, h, (lo, hi) = lay(photo, v, m)
        ys, z, _ = envelope(v, m, q[:, 1].min(), q[:, 1].max(), h)
        ax.plot(z, ys, colour + "-", lw=1, label=name)
        ax.plot(q[:, 0], q[:, 1], colour + ".", ms=1.5)
    ax.axhline(lo, color="grey", lw=0.5)
    ax.axhline(hi, color="grey", lw=0.5)
    ax.set_aspect("equal")
    ax.legend()
    fig.savefig(os.path.join(folder, person[-8:] + ".png"), dpi=90)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--ridges", default="0.3,1,3,10")
    ap.add_argument("--keys", default="Nose_Dorsum_Hump,Nose_Dorsum_Curve", help="the sliders the profile moves")
    ap.add_argument("--plot", help="a folder for each person's outlines: the photo's laid on ours, before and after")
    args = ap.parse_args()
    import ava_learn as L
    models = {b: e.load_model(os.path.join(args.models, "model_" + b)) for b in e.BASES}
    for b in e.BASES:
        models[b]["mp"] = json.load(open(os.path.join(args.models, "model_" + b + ".json")))["mediapipe"]
    chosen = {}
    for line in open(os.path.join(args.models, "metrical.txt")):
        m = re.match(r"(\S+) \|.*\((male|female)\)$", line.strip())
        if m:
            chosen[m.group(1)] = "default_" + m.group(2)
    variants = json.load(open(os.path.join(args.models, "variants1.json")))["sets"]
    reader = np.load(os.path.expanduser("~/datasets/ava256/ava_reader.npz"))
    keys = bytes(reader["reader_keys"]).decode().split("\n")
    rows = [json.loads(l) for l in open(os.path.join(NOW, "profiles2_val.jsonl"))]
    people = {}
    for r in rows:
        if r["found"]:
            people.setdefault(r["path"].split("/")[-3], []).append(r)
    ridges = [float(x) for x in args.ridges.split(",")]
    errs = {"front": [], **{f"profile ridge {x:g}": [] for x in ridges}}
    nose_errs = {k: [] for k in errs}
    for person, photos in sorted(people.items()):
        profiles = [p for p in photos if "profile" in p and abs(p["turn"]) >= P.PROFILE_TURN]
        if not profiles:
            continue
        base = chosen[person[-8:]]
        b = e.BASES.index(base)
        m = models[base]
        front = min(photos, key=lambda p: abs(p["turn"]))
        pts = np.array(front["points"]).reshape(-1, 3)
        ref = reader[f"mean_landmarks_{b}_1"].reshape(478, 3)
        x = (L.align_to(pts, ref).ravel() - reader[f"feature_mean_{b}_1"]) / reader[f"feature_std_{b}_1"]
        read = dict(zip(keys, x @ reader[f"beta_{b}_1"].reshape(len(x), -1) + reader[f"weight_mean_{b}_1"]))
        fitted = variants[base][person]["front_only|landmarks_p1"]
        w0 = {k: 0.5 * read.get(k, 0.0) + 0.5 * fitted.get(k, 0.0) for k in keys}
        obj = [f for f in os.listdir(f"{NOW}/scans/{person}") if f.endswith(".obj")][0]
        v, _ = e.load_obj(f"{NOW}/scans/{person}/{obj}")
        lmk = e.load_pp(f"{NOW}/scans_lmks_onlypp/{person}/{obj.replace('.obj', '_picked_points.pp')}")
        scan = e.crop(v, lmk)
        nose = np.linalg.norm(scan - (lmk[4] + 0.5 * (0.5 * (lmk[1] + lmk[2]) - lmk[4])), axis=1) < 25

        def judge(name, w):
            d = e.scan_error(scan, e.align(scan, lmk, e.mesh_of(m, w), m, False), m)
            errs[name].append(d.mean())
            nose_errs[name].append(d[nose].mean())

        judge("front", w0)
        for ridge in ridges:
            ws = [fit(p, m, w0, args.keys.split(","), ridge) for p in profiles]
            judge(f"profile ridge {ridge:g}", {k: float(np.mean([w.get(k, 0.0) for w in ws])) for k in set(w0) | set(ws[0])})
        if args.plot:
            plot(args.plot, person, profiles[0], m, w0, fit(profiles[0], m, w0, args.keys.split(","), ridges[0]))
        print(person[-8:], " ".join(f"{k.split()[-1]}: {errs[k][-1]:.2f}/{nose_errs[k][-1]:.2f}" for k in errs), flush=True)
    print(f"\n{len(errs['front'])} NoW people with a profile (metrical, mean per person: face / nose within 25 mm):")
    for k in errs:
        print(f"  {k:22s} face {np.mean(errs[k]):.3f} mm, nose {np.mean(nose_errs[k]):.3f} mm")


if __name__ == "__main__":
    main()
