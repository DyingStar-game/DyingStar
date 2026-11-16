"""Learn the photo reading on real faces: MediaPipe's landmarks of Ava-256's photos -> the creator's shape sliders
fitted to their meshes (ava_targets.py), a ridge per base body; judged on NoW's scans (eval_now's protocol: the
model dir holds eval_now.tscn's model_*, its metrical.txt run -- each NoW person's base -- and variants1.json, the
landmark fit to blend with).

    python3 -I ava_learn.py <eval_now dir> [--views front|front,left|front,right|front,left,right]
    python3 -I ava_learn.py <eval_now dir> --export ava_reader.npz   # then pack_face_fit.tscn --reader=
"""
import argparse, json, os, re, sys, glob
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))  # eval_now
import eval_now as e
from ava_common import DATA, ROOT, load_landmarks

NOW = os.path.expanduser("~/datasets/now")
SIDE_MIN, SIDE_MAX = 0.35, 1.6  # FaceFit.turn() of a usable side photo (the game's MIN_SIDE_TURN .. a profile)


def turn(p):
    span = np.linalg.norm(p[234, :2] - p[454, :2])
    return (p[1, 0] - 0.5 * (p[234, 0] + p[454, 0])) / max(span, 1e-6)


def normalise(p):
    """Landmarks centred and scaled (pixels, MediaPipe's depth), y up."""
    q = p * [1, -1, -1]
    q = q - q.mean(0)
    return q / np.sqrt((q ** 2).sum(1).mean())


def align_to(p, ref):
    """p (pixels, MediaPipe's depth) turned to (x, -y, -z) and moved onto ref by a least-squares similarity: as
    FaceFitNative's Similarity (Horn: scale = sum (ref - mr) . R (p - mp) / sum |p - mp|^2)."""
    q = p * [1, -1, -1]
    mq, mr = q.mean(0), ref.mean(0)
    a, b = q - mq, ref - mr
    u, sig, vt = np.linalg.svd(b.T @ a)
    d = np.sign(np.linalg.det(u @ vt))
    r = u @ np.diag([1, 1, d]) @ vt
    s = (b * (a @ r.T)).sum() / (a ** 2).sum()
    return s * (a @ r.T) + mr


class Reader:
    """Ridge from the views' aligned landmarks to the sliders."""

    def __init__(self, views, alpha):
        self.views, self.alpha = views, alpha

    def features(self, samples, fit=False):
        cols = []
        for v in self.views:
            pts = [s[v] for s in samples]
            if fit:
                ref = normalise(pts[0])
                for _ in range(5):
                    ref = normalise(np.mean([align_to(p, ref) for p in pts], 0))
                setattr(self, "ref_" + v, ref)
            ref = getattr(self, "ref_" + v)
            cols.append(np.array([align_to(p, ref).ravel() for p in pts]))
        x = np.hstack(cols)
        if fit:
            self.mean, self.std = x.mean(0), x.std(0) + 1e-6
        return (x - self.mean) / self.std

    def fit(self, samples, y, metric=None):
        x = self.features(samples, fit=True)
        self.metric = metric if metric is not None else np.eye(y.shape[1])
        y = y @ self.metric.T
        self.ymean = y.mean(0)
        a = x.T @ x + self.alpha * np.eye(x.shape[1])
        self.beta = np.linalg.solve(a, x.T @ (y - self.ymean))
        return self

    def predict(self, samples):
        return np.linalg.solve(self.metric, (self.features(samples) @ self.beta + self.ymean).T).T


def ava_samples(views, base, targets, lm):
    samples, ys, groups = [], [], []
    keys = None
    for ident, frames in sorted(targets.items()):
        for frame, out in frames.items():
            s = {}
            for v in views:
                path = f"{DATA}/{ident}/{frame}_{v}.png"
                if path not in lm:
                    break
                s[v] = lm[path]
            else:
                w = out[base]["weights"]
                keys = keys or sorted(w)
                samples.append(s)
                ys.append([w[k] for k in keys])
                groups.append(ident)
    return samples, np.array(ys), np.array(groups), keys


def now_sets(views):
    """Per NoW validation person, their neutral photos as views: the least turned is the front; the sides the
    nearest +-0.57 turn within the usable range (as eval_now.gd picks them)."""
    lm = {}
    for line in open(os.path.join(NOW, "landmarks_val.jsonl")):
        r = json.loads(line)
        if r["found"] and "multiview_neutral" in r["path"]:
            lm[r["path"]] = np.array(r["points"]).reshape(-1, 3)
    people = {}
    for path, p in lm.items():
        people.setdefault(path.split("/")[-3], []).append((turn(p), p))
    out = {}
    for person, photos in people.items():
        photos.sort(key=lambda t: abs(t[0]))
        s = {"front": photos[0][1]}
        for name, sign in (("left", 1), ("right", -1)):  # Ava's "left" camera: turn() > 0
            cand = [t for t in photos if sign * t[0] >= SIDE_MIN and abs(t[0]) <= SIDE_MAX]
            if cand:
                s[name] = min(cand, key=lambda t: abs(t[0] - sign * 0.57))[1]
        # MediaPipe's turn sign vs the Ava view names: checked below on Ava (left = negative turn).
        if all(v in s for v in views):
            out[person] = s
    return out


SETS = {1: ["front"], 3: ["front", "left"], 5: ["front", "right"], 7: ["front", "left", "right"]}


def export(args, targets, lm, models):
    """Per base and view set (mask: 1 front, 2 left -- turn() > 0, 4 right), the reader learnt on every identity,
    at the alpha the cross-validation chose for the front alone (1000)."""
    out = {}
    keys_all = None
    masks, bases = [], []
    for b, base in enumerate(e.BASES):
        for mask, views in SETS.items():
            samples, y, groups, keys = ava_samples(views, base, targets, lm)
            keys_all = keys_all or keys
            assert keys == keys_all
            r = Reader(views, 1000.0).fit(samples, y)
            tag = f"{b}_{mask}"
            out["mean_landmarks_" + tag] = np.concatenate([getattr(r, "ref_" + v).ravel() for v in views]).astype(np.float32)
            out["feature_mean_" + tag] = r.mean.astype(np.float32)
            out["feature_std_" + tag] = r.std.astype(np.float32)
            out["beta_" + tag] = r.beta.astype(np.float32).ravel()
            out["weight_mean_" + tag] = r.ymean.astype(np.float32)
            masks.append(mask)
            bases.append(b)
            print(f"{base} views {views}: {len(samples)} photos, {r.beta.shape[0]} features")
    out["reader_masks"] = np.array(masks, np.int32)
    out["reader_female"] = np.array(bases, np.int32)
    out["reader_keys"] = np.frombuffer("\n".join(keys_all).encode(), np.uint8)
    np.savez(args.export, **out)
    print("->", args.export, sum(v.nbytes for v in out.values()) / 1e6, "MB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models")
    ap.add_argument("--views", default="front")
    ap.add_argument("--alphas", default="10,100,1000,10000,100000")
    ap.add_argument("--export", help="write every view set's readers to this npz (pack_face_fit.tscn --reader=) and stop")
    args = ap.parse_args()
    views = args.views.split(",")
    targets = json.load(open(os.path.join(ROOT, "targets.json")))
    lm = load_landmarks()
    print("Ava turns: left %.2f front %.2f right %.2f (median)" % tuple(
        np.median([turn(p) for k, p in lm.items() if k.endswith(f"_{v}.png")]) for v in ("left", "front", "right")))
    models = {b: e.load_model(os.path.join(args.models, "model_" + b)) for b in e.BASES}
    chosen = {}
    for line in open(os.path.join(args.models, "metrical.txt")):
        m = re.match(r"(\S+) \|.*\((male|female)\)$", line.strip())
        if m:
            chosen[m.group(1)] = "default_" + m.group(2)
    if args.export:
        export(args, targets, lm, models)
        return
    readers = {}
    for base in e.BASES:
        samples, y, groups, keys = ava_samples(views, base, targets, lm)
        m = models[base]
        order = [m["keys"].index(k) for k in keys]
        face = m["deltas"][order][:, ::4].reshape(len(keys), -1)  # every 4th vertex of the face: the surface's metric
        metric = np.linalg.cholesky(face @ face.T / face.shape[1] + 1e-9 * np.eye(len(keys))).T
        ids = np.unique(groups)
        folds = np.array_split(np.random.default_rng(0).permutation(ids), 5)
        best = None
        for alpha in [float(a) for a in args.alphas.split(",")]:
            err = []
            for fold in folds:
                test = np.isin(groups, fold)
                r = Reader(views, alpha).fit([s for s, t in zip(samples, test) if not t], y[~test], metric)
                diff = (r.predict([s for s, t in zip(samples, test) if t]) - y[test]) @ metric.T
                err.append(np.sqrt((diff ** 2).sum(1)).mean())
            base_err = np.sqrt((((y - y.mean(0)) @ metric.T) ** 2).sum(1)).mean()
            print(f"  {base} alpha {alpha:g}: surface error {np.mean(err):.3f} mm rms (guessing the mean {base_err:.3f})")
            if best is None or np.mean(err) < best[0]:
                best = (np.mean(err), alpha)
        readers[base] = (Reader(views, best[1]).fit(samples, y, metric), keys)
    # NoW: the learnt reading against the scans.
    sets = now_sets(views)
    variants = json.load(open(os.path.join(args.models, "variants1.json")))["sets"]
    blends = (0.0, 0.25, 0.5, 0.75, 1.0)
    errs, blend_errs = [], {a: [] for a in blends}
    for person, s in sorted(sets.items()):
        base = chosen[person[-8:]]
        m = models[base]
        reader, keys = readers[base]
        w = dict(zip(keys, reader.predict([s])[0]))
        obj = [f for f in os.listdir(f"{NOW}/scans/{person}") if f.endswith(".obj")][0]
        v, _ = e.load_obj(f"{NOW}/scans/{person}/{obj}")
        lmk = e.load_pp(f"{NOW}/scans_lmks_onlypp/{person}/{obj.replace('.obj', '_picked_points.pp')}")
        scan = e.crop(v, lmk)
        d = e.scan_error(scan, e.align(scan, lmk, e.mesh_of(m, w), m, False), m)
        errs.append(d.mean())
        fitted = variants[base][person]["front_only|landmarks_p1"]
        for a in blends:
            wb = {k: a * w.get(k, 0.0) + (1 - a) * fitted.get(k, 0.0) for k in keys}
            blend_errs[a].append(e.scan_error(scan, e.align(scan, lmk, e.mesh_of(m, wb), m, False), m).mean())
    print(f"NoW, views {views}, {len(errs)} people: learnt on Ava-256 {np.mean(errs):.3f} mm (median {np.median(errs):.3f}); "
          f"to beat: landmark fit 1.784, base face 1.961")
    for a in blends:
        print(f"  blend {a:.2f} learnt + {1 - a:.2f} landmark fit: {np.mean(blend_errs[a]):.3f} mm")


if __name__ == "__main__":
    main()
