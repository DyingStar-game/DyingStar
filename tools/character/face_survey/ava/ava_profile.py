"""Does a profile photo help the photo reading? The same reading as ava_learn.py (a ridge from the front photo's
aligned landmarks to the sliders fitted to Ava-256's meshes), with a profile's outline added to its features:
PhotoProfile.measure's face-skin edge, row by row, as the edge's distance in front of the nose's tip at fixed
heights from it (in the face's heights, the nose facing +x). Learnt on Ava-256's profile views (fetch.py
--profiles, then dump_landmarks.tscn --profile into profiles.jsonl), judged on NoW's people who have a profile.

    python3 -I ava_profile.py <eval_now dir> [--train left75,left90,right75,right90] [--landmarks]
"""
import argparse, json, os, re, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))  # eval_now
import eval_now as e
import ava_learn as L
from ava_common import DATA, ROOT, load_landmarks

NOW = os.path.expanduser("~/datasets/now")
GRID = np.arange(-0.55, 0.62, 0.025)  # heights from the nose's tip (face heights, y down): forehead .. under the chin
MAX_GAP = 0.03
PROFILE_TURN = 1.0  # NoW photos turned this far (FaceFit.turn(): loose on a profile) are its profiles, ~65 degrees on


def outline(profile):
    """The profile's outline as GRID's edges (NaN where it has no row near)."""
    p = np.array(profile["points"], float).reshape(-1, 2)
    tip = np.array(profile["nose_tip"], float)
    h = float(profile["height"])
    x = (p[:, 0] - tip[0]) * profile["facing"] / h
    y = (p[:, 1] - tip[1]) / h
    order = np.argsort(y)
    x, y = x[order], y[order]
    out = np.interp(GRID, y, x)
    i = np.clip(np.searchsorted(y, GRID), 1, len(y) - 1)
    gap = np.minimum(np.abs(y[i] - GRID), np.abs(y[i - 1] - GRID))
    out[(GRID < y[0]) | (GRID > y[-1]) | (gap > MAX_GAP)] = np.nan
    return out


OUTLIER = 0.04  # laid outline points further than this from the mean (face heights) are left out: hair, a lamp, a hand
MIN_RUN = 30  # rows: an outline whose run is shorter is not read
TRIM = 0.8
COVERAGE = 0.5  # the mean outline: the heights at least this share of outlines reach
NOSE_SPAN = (-0.22, 0.12)  # the nose on the mean outline (root to base): what is read, so not what lays the outline  # the share of an outline's points (nearest the mean) its alignment follows
FINE = np.arange(-0.7, 0.9, 0.005)


def clean(profile):
    """The outline in face heights from the nose's tip, the nose towards +x, top to bottom (None when too short)."""
    p = np.array(profile["points"], float).reshape(-1, 2)
    tip = np.array(profile["nose_tip"], float)
    h = float(profile["height"])
    q = np.stack([(p[:, 0] - tip[0]) * profile["facing"] / h, (p[:, 1] - tip[1]) / h], 1)
    q = q[np.argsort(q[:, 1])]
    return q if len(q) >= MIN_RUN else None


def similarity2(src, dst, w):
    w = w[:, None] / w.sum()
    ms, md = (src * w).sum(0), (dst * w).sum(0)
    a, b = (src - ms) * np.sqrt(w), (dst - md) * np.sqrt(w)
    u, _, vt = np.linalg.svd(b.T @ a)
    r = u @ np.diag([1, np.sign(np.linalg.det(u @ vt))]) @ vt
    sc = np.sqrt((b ** 2).sum() / max((a ** 2).sum(), 1e-12))  # Horn's symmetric scale: a curve's nearest points pull no collapse
    return lambda x: sc * ((x - ms) @ r.T) + md


def resample(q, grid):
    out = np.interp(grid, q[:, 1], q[:, 0])
    i = np.clip(np.searchsorted(q[:, 1], grid), 1, len(q) - 1)
    gap = np.minimum(np.abs(q[i, 1] - grid), np.abs(q[i - 1, 1] - grid))
    out[(grid < q[0, 1]) | (grid > q[-1, 1]) | (gap > MAX_GAP)] = np.nan
    return out


class Outlines:
    """Outlines laid on their mean by a 2D similarity (trimmed ICP): the head's pitch, the photo's scale and the face
    detector's loose box on a profile out, the shape left."""

    def fit(self, profiles, rounds=4):
        from scipy.spatial import cKDTree
        self.tree = cKDTree
        runs = [r for r in (clean(p) for p in profiles) if r is not None]
        mean = np.nanmedian([resample(r, FINE) for r in runs], 0)
        for _ in range(rounds):
            self.set_mean(mean)
            laid = [self.lay(r) for r in runs]
            xs = np.array([resample(self.inliers(q), FINE) for q in laid])
            mean = np.where(np.mean(~np.isnan(xs), 0) > COVERAGE, np.nanmedian(xs, 0), np.nan)
        self.set_mean(mean)
        return self

    def set_mean(self, mean):
        ok = ~np.isnan(mean)
        self.mean = np.stack([mean[ok], FINE[ok]], 1)
        self.kd = self.tree(self.mean)
        y = self.mean[:, 1]
        self.weight = np.where((y > NOSE_SPAN[0]) & (y < NOSE_SPAN[1]), 0.0, 1.0)

    def lay(self, run, iterations=15):
        q = run.copy()
        for _ in range(iterations):
            d, j = self.kd.query(q)
            keep = (d <= np.quantile(d, TRIM)) & (self.weight[j] > 0.0)
            if keep.sum() < 10:
                break
            q = similarity2(q[keep], self.mean[j[keep]], self.weight[j[keep]])(q)
        return q

    def features(self, profile):
        run = clean(profile)
        if run is None:
            return np.full(len(GRID), np.nan)
        return resample(self.inliers(self.lay(run)), GRID)

    def inliers(self, q):
        d, _ = self.kd.query(q)
        q = q[d <= OUTLIER]
        return q[np.argsort(q[:, 1])] if len(q) >= 2 else np.array([[0.0, -9.0], [0.0, -8.9]])


class Reader:
    """Ridge from the front's aligned landmarks (+ the profile's outline, + its aligned landmarks) to the sliders."""

    def __init__(self, alpha, parts):
        self.alpha, self.parts = alpha, parts

    def features(self, samples, fit=False):
        cols = []
        if "front" in self.parts:
            pts = [s["front"] for s in samples]
            if fit:
                ref = L.normalise(pts[0])
                for _ in range(5):
                    ref = L.normalise(np.mean([L.align_to(p, ref) for p in pts], 0))
                self.ref = ref
            cols.append(np.array([L.align_to(p, self.ref).ravel() for p in pts]))
        if "outline" in self.parts:
            cols.append(np.array([s["outline"] for s in samples]))
        if "laid" in self.parts:  # laid once for every sample (main): the laying never sees the targets
            cols.append(np.array([s["laid"] for s in samples]))
        if "profile_landmarks" in self.parts:
            pts = [s["profile_points"] * [s["facing"], 1, s["facing"]] for s in samples]  # mirrored to face +x
            if fit:
                ref = L.normalise(pts[0])
                for _ in range(5):
                    ref = L.normalise(np.mean([L.align_to(p, ref) for p in pts], 0))
                self.pref = ref
            cols.append(np.array([L.align_to(p, self.pref).ravel() for p in pts]))
        x = np.hstack(cols)
        if fit:
            self.mean, self.std = np.nanmean(x, 0), np.nanstd(x, 0) + 1e-6
        z = (x - self.mean) / self.std
        return np.nan_to_num(z, nan=0.0)

    def fit(self, samples, y, metric):
        x = self.features(samples, fit=True)
        self.metric = metric
        y = y @ metric.T
        self.ymean = y.mean(0)
        self.beta = np.linalg.solve(x.T @ x + self.alpha * np.eye(x.shape[1]), x.T @ (y - self.ymean))
        return self

    def predict(self, samples):
        return np.linalg.solve(self.metric, (self.features(samples) @ self.beta + self.ymean).T).T


def ava_samples(base, targets, lm, profiles, views, laid):
    samples, ys, groups, keys = [], [], [], None
    for ident, frames in sorted(targets.items()):
        for frame, out in frames.items():
            front = lm.get(f"{DATA}/{ident}/{frame}_front.png")
            if front is None:
                continue
            for v in views:
                r = profiles.get(f"{DATA}/{ident}/{frame}_{v}.png")
                if r is None:
                    continue
                w = out[base]["weights"]
                keys = keys or sorted(w)
                samples.append({"front": front, "outline": outline(r["profile"]), "facing": r["profile"]["facing"], "laid": laid[f"{DATA}/{ident}/{frame}_{v}.png"],
                                "profile_points": np.array(r["points"]).reshape(-1, 3)})
                ys.append([w[k] for k in keys])
                groups.append(ident)
    return samples, np.array(ys), np.array(groups), keys


def metric_of(m, keys):
    order = [m["keys"].index(k) for k in keys]
    face = m["deltas"][order][:, ::4].reshape(len(keys), -1)
    return np.linalg.cholesky(face @ face.T / face.shape[1] + 1e-9 * np.eye(len(keys))).T


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models")
    ap.add_argument("--train", default="left75,left90,right75,right90")
    ap.add_argument("--alphas", default="1000,3000,10000")
    args = ap.parse_args()
    targets = json.load(open(os.path.join(ROOT, "targets.json")))
    lm = load_landmarks()
    profiles = {}
    for line in open(os.path.join(ROOT, "profiles.jsonl")):
        r = json.loads(line)
        if r["found"] and "profile" in r:
            profiles[r["path"]] = r
    views = args.train.split(",")
    for v in ("left75", "left90", "right75", "right90"):
        n = sum(k.endswith(f"_{v}.png") for k in profiles)
        print(f"Ava {v}: {n} profiles measured")
    models = {b: e.load_model(os.path.join(args.models, "model_" + b)) for b in e.BASES}
    chosen = {}
    for line in open(os.path.join(args.models, "metrical.txt")):
        m = re.match(r"(\S+) \|.*\((male|female)\)$", line.strip())
        if m:
            chosen[m.group(1)] = "default_" + m.group(2)
    variants = json.load(open(os.path.join(args.models, "variants1.json")))["sets"]
    configs = {"front": ["front"], "front+laid outline": ["front", "laid"]}
    outlines = Outlines().fit([r["profile"] for r in profiles.values()])
    laid = {path: outlines.features(r["profile"]) for path, r in profiles.items()}
    print(f"outlines laid; mean outline from {outlines.mean[0, 1]:+.2f} to {outlines.mean[-1, 1]:+.2f} face heights", flush=True)
    readers = {}
    for base in e.BASES:
        samples, y, groups, keys = ava_samples(base, targets, lm, profiles, views, laid)
        metric = metric_of(models[base], keys)
        ids = np.unique(groups)
        folds = np.array_split(np.random.default_rng(0).permutation(ids), 5)
        base_err = np.sqrt((((y - y.mean(0)) @ metric.T) ** 2).sum(1)).mean()
        for name, parts in configs.items():
            best = None
            for alpha in [float(a) for a in args.alphas.split(",")]:
                err = []
                for fold in folds:
                    test = np.isin(groups, fold)
                    r = Reader(alpha, parts).fit([s for s, t in zip(samples, test) if not t], y[~test], metric)
                    diff = (r.predict([s for s, t in zip(samples, test) if t]) - y[test]) @ metric.T
                    err.append(np.sqrt((diff ** 2).sum(1)).mean())
                if best is None or np.mean(err) < best[0]:
                    best = (np.mean(err), alpha)
            print(f"  {base} {name:24s} cross-validated {best[0]:.3f} mm rms at alpha {best[1]:g} "
                  f"(guessing the mean {base_err:.3f}; {len(samples)} samples, {len(ids)} people)", flush=True)
            readers[(base, name)] = (Reader(best[1], parts).fit(samples, y, metric), keys)
    # NoW: people with a profile.
    rows = [json.loads(l) for l in open(os.path.join(NOW, "profiles2_val.jsonl"))]
    people = {}
    for r in rows:
        if r["found"]:
            people.setdefault(r["path"].split("/")[-3], []).append(r)
    blends = (0.5, 0.75, 1.0)
    errs = {(n, a): [] for n in configs for a in blends}
    nose = {k: [] for k in errs}
    for person, photos in sorted(people.items()):
        profs = [p for p in photos if "profile" in p and abs(p["turn"]) >= PROFILE_TURN]
        if not profs:
            continue
        base = chosen[person[-8:]]
        m = models[base]
        front = min(photos, key=lambda p: abs(p["turn"]))
        fpts = np.array(front["points"]).reshape(-1, 3)
        obj = [f for f in os.listdir(f"{NOW}/scans/{person}") if f.endswith(".obj")][0]
        v, _ = e.load_obj(f"{NOW}/scans/{person}/{obj}")
        lmk = e.load_pp(f"{NOW}/scans_lmks_onlypp/{person}/{obj.replace('.obj', '_picked_points.pp')}")
        scan = e.crop(v, lmk)
        near_nose = np.linalg.norm(scan - (lmk[4] + 0.5 * (0.5 * (lmk[1] + lmk[2]) - lmk[4])), axis=1) < 25
        fitted = variants[base][person]["front_only|landmarks_p1"]
        line = []
        for name in configs:
            reader, keys = readers[(base, name)]
            ss = [{"front": fpts, "outline": outline(p["profile"]), "facing": p["profile"]["facing"], "laid": outlines.features(p["profile"]),
                   "profile_points": np.array(p["points"]).reshape(-1, 3)} for p in profs]
            w = dict(zip(keys, reader.predict(ss).mean(0)))
            for a in blends:
                wb = {k: a * w.get(k, 0.0) + (1 - a) * fitted.get(k, 0.0) for k in keys}
                d = e.scan_error(scan, e.align(scan, lmk, e.mesh_of(m, wb), m, False), m)
                errs[(name, a)].append(d.mean())
                nose[(name, a)].append(d[near_nose].mean())
            line.append(f"{name}: {errs[(name, 0.5)][-1]:.2f}/{nose[(name, 0.5)][-1]:.2f}")
        print(person[-8:], " | ".join(line), flush=True)
    print(f"\nNoW, {len(errs[('front', 0.5)])} people with a profile (metrical; face / nose within 25 mm):")
    for (name, a), v in errs.items():
        print(f"  {name:24s} blend {a:.2f} learnt: face {np.mean(v):.3f} mm, nose {np.mean(nose[(name, a)]):.3f} mm")


if __name__ == "__main__":
    main()
