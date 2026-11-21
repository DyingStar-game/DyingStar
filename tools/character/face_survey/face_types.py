#!/usr/bin/env python3
"""Faces' types of one origin, per sex, trait and age band, learnt on FFHQ -> <origin>_face_types.json (FaceTypes).

The photos: FFHQ's adults FairFace reads as White (ethnicity.py), their shapes fitted as the creator's "From photos"
fits them (fit_photos.tscn: FLAME's directions, the jaw's and nose's sliders, the reader's) over a European base of
the photo's sex and age. Per photo and trait, the trait's shape is where our head's MediaPipe landmarks of that
trait lie once those weights are applied (linear: the bank's shape keys sampled at the landmarks, corr.npz) -- a
nose is compared as a nose, not as FLAME's directions, which each move the whole face.

Per sex and trait: the shapes' principal components, then k-means (TYPES groups, best of RESTARTS, groups under
MIN_GROUP merged away): the TYPES are the same at every age, their shares change with it. Per age band (BANDS,
merged with the next older one while under MIN_BAND photos): its most frequent types until they cover COVER of its
photos (3 or 4: the shares are flat; the rarest types, the farthest from the mean, stay out), their shares summing to
1 (a type judged wrong by eye, --reject, is left out: the next most frequent takes its place). The mouth and the eyes
are read on photos without a marked smile only (FFHQ smiles a lot: FaceFit takes the expression apart, but a wide
smile still bends the lips and closes the eyes).

Each type becomes a weight offset (`delta`): the likeliest face with the type's mean shape on its trait -- Gaussian
conditioning on the fitted faces' own covariance of weights, so the rest of the face moves as it moves with that
trait in real faces (offsets that left the rest still had to cancel large FLAME directions against each other, faces
nobody has). One type per trait adds up; `gain` then scales every offset so that a face's summed types spread no more
than the fitted faces do.
`mean` is the sex's mean face over our base. `noise`, per FLAME direction, what a random face still draws around
them: FLAME's own spread (1 deviation, measured on 3D scans -- the photos' fits are shrunk by their prior, 0.3 of it)
less what the types already spread along that direction, so that a face's whole spread stays FLAME's.
--fit-bias takes off every photo what the fit itself adds to any face (fit_bias.py: renders of known random faces
fitted the same way): their outline wider than they are, mostly.
`shrink` per trait compares, on our head's landmarks, the spread of the photos' fitted shapes to that of FLAME's
random faces: under 1, the fits flatten real faces (their types are told too timidly).

Only aggregates leave ~/datasets: every type is the mean of at least MIN_GROUP faces.

Origins (--origin, FairFace's group of the photos): European (White, 20 041 photos), African (Black, 1 520), East
Asian (East Asian, 2 399 women and 346 men, --min-photos 300: an origin is typed for both sexes or not at all). A sex
with fewer than MIN_PHOTOS fitted photos is left out of the file: its random faces stay FLAME's alone (2026-11-21:
FFHQ's Indian, Latino, Middle Eastern and Southeast Asian adults are 33 to 325 per sex: no file).

    python3 face_types.py --fits '~/datasets/ffhq/survey/eu_fit/fit_*.jsonl' \\
        --photos ~/datasets/ffhq/survey/european.json \\
        --bank build/character/human_bank.npz --corr ~/datasets/ffhq/survey/corr.npz [--out <json>] \\
        [--origin European] [--reject female:nose:E ...]
    (the bank: the main checkout's build/character/human_bank.npz, with FLAME's keys)
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
from scipy.optimize import linear_sum_assignment

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fit import Bank, sample  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
OUT = os.path.join(ROOT, "assets/_universe/characters/human/european_face_types.json")
FACE_STATS = os.path.join(ROOT, "assets/_universe/characters/human/face_stats.json")
FLAME_PREFIX = "FLAME_Identity_"
FLAME_RANGE = 3.0

# MediaPipe's face mesh contours (mediapipe tasks FaceLandmarksConnections).
LIPS = [0, 13, 14, 17, 37, 39, 40, 61, 78, 80, 81, 82, 84, 87, 88, 91, 95, 146, 178, 181, 185, 191, 267, 269, 270, 291,
        308, 310, 311, 312, 314, 317, 318, 321, 324, 375, 402, 405, 409, 415]
EYES = [249, 263, 362, 373, 374, 380, 381, 382, 384, 385, 386, 387, 388, 390, 398, 466,
        7, 33, 133, 144, 145, 153, 154, 155, 157, 158, 159, 160, 161, 163, 173, 246]
BROWS = [276, 282, 283, 285, 293, 295, 296, 300, 334, 336, 46, 52, 53, 55, 63, 65, 66, 70, 105, 107]
OVAL = [10, 21, 54, 58, 67, 93, 103, 109, 127, 132, 136, 148, 149, 150, 152, 162, 172, 176, 234, 251, 284, 288, 297, 323,
        332, 338, 356, 361, 365, 377, 378, 379, 389, 397, 400, 454]
NOSE = [1, 2, 4, 5, 6, 19, 45, 48, 64, 94, 97, 98, 115, 168, 195, 197, 220, 275, 278, 294, 326, 327, 344, 440]
CHIN = [18, 175, 199, 200, 201, 208, 428, 421]  # the chin's front, under the lower lip
CHEEKS = [50, 280, 123, 352, 116, 345, 117, 346, 118, 347, 101, 330, 36, 266, 205, 425]
SUBNASALE = 2  # the oval's points under it are the jaw's, the others the face's outline
TRAITS = ["nose", "mouth", "eyes", "brows", "jaw", "face"]
NEUTRAL_TRAITS = ("mouth", "eyes")  # read on photos without a marked smile
MAX_SMILE = 0.5  # FFHQ's label (Azure), 0..1
MAX_MOUTH_OPEN = 0.3  # FaceFit's FACS_Mouth_Large_Opened
WORST_FITS = 0.05  # the share of photos whose landmark fit is worst, left out
TYPES = 6
RESTARTS = 20
MIN_GROUP = 40
MIN_PHOTOS = 600  # a sex's fitted photos under this: too few to learn its types (6 types of 40, bands of 150)
COMPONENTS = 0.95  # the shapes' variance the principal components keep (at most MAX_COMPONENTS)
MAX_COMPONENTS = 12
BANDS = [(18, 20), (21, 25), (26, 30), (31, 35), (36, 40), (41, 45), (46, 50), (51, 55), (56, 60), (61, 65), (66, 90)]
MIN_BAND = 150
COVER = 0.70  # a band keeps its most frequent types until they cover this share of its photos
LANDMARK_NOISE = 0.05  # mm^2 per landmark coordinate: how loosely a type's offset must make its mean shape
COVARIANCE_FLOOR = 1e-3  # added to the weights' covariance's diagonal (shape-key units squared)
SMALLEST = 0.01  # stored values under this are left out of the file (and off the wire)
# The keys a type, the mean face and a random face are made of: FaceFit's own (FLAME's directions, the jaw's and the
# nose's sliders, face_fit.gd). The reader learnt on Ava-256 adds the mouth's and eyes' sliders to a photo's look --
# drawn at random, those made pouts and doll's eyes, and their mean alone (lips +0.39, upper corners +0.30) passed the
# creator's limits. They still shape each photo's traits; the types are made without them.
JAW_KEYS = ["Jaw_Mandible", "Jaw_Mandible_GonialAngle", "Jaw_Definition", "Chin_Width"]
NOSE_KEYS = ["Nose_NasalBone", "Nose_NasalBone_AnteriorNasalAperature", "Nose_NasalBone_AnteriorNasalSpine", "Nose_Potrusion",
             "Nose_NasalAngle", "Nose_NostrilSize", "Nose_Tip_Potrusion", "Nose_BottomFlatness", "Nose_BridgeProminence"]
MEAN_PRIOR = 0.01  # the mean face's fit: the covariance prior's share (a mean is many faces: barely held)


def kmeans(x, k, rng):
    best, best_cost = None, np.inf
    for _ in range(RESTARTS):
        centres = [x[rng.integers(len(x))]]
        for _c in range(1, k):  # k-means++
            d = np.min(((x[:, None, :] - np.array(centres)[None]) ** 2).sum(-1), 1)
            centres.append(x[rng.choice(len(x), p=d / d.sum())])
        c = np.array(centres)
        for _it in range(100):
            label = ((x[:, None, :] - c[None]) ** 2).sum(-1).argmin(1)
            new = np.array([x[label == j].mean(0) if (label == j).any() else c[j] for j in range(k)])
            if np.allclose(new, c):
                break
            c = new
        cost = ((x - c[label]) ** 2).sum()
        if cost < best_cost:
            best, best_cost = (label, c), cost
    return best


def agreement(a, b, k):
    m = np.zeros((k, k))
    for i, j in zip(a, b):
        m[i, j] += 1
    r, c = linear_sum_assignment(-m)
    return m[r, c].sum() / len(a)


def regions(neutral):
    below = [i for i in OVAL if neutral[i, 1] < neutral[SUBNASALE, 1]]
    above = [i for i in OVAL if i not in below]
    return {"nose": NOSE, "mouth": LIPS, "eyes": EYES, "brows": BROWS, "jaw": sorted(set(below + CHIN)),
            "face": sorted(set(above + CHEEKS))}


def band_of(years, bands):
    for b, (lo, hi) in enumerate(bands):
        if years < hi + 1:
            return b
    return len(bands) - 1


def merged_bands(years):
    bands = [list(b) for b in BANDS]
    while True:
        counts = [sum(1 for y in years if band_of(y, bands) == b) for b in range(len(bands))]
        thin = [b for b, n in enumerate(counts) if n < MIN_BAND]
        if not thin or len(bands) == 1:
            return [tuple(b) for b in bands], counts
        b = thin[-1]  # the oldest thin band joins its younger neighbour (the young ones are many)
        other = b - 1 if b > 0 else b + 1
        lo, hi = min(bands[b][0], bands[other][0]), max(bands[b][1], bands[other][1])
        bands[min(b, other)] = [lo, hi]
        del bands[max(b, other)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fits", required=True, help="glob of fit_photos.tscn's JSON lines")
    ap.add_argument("--photos", required=True, help="<origin>.json: per photo its path, sex, age, smile")
    ap.add_argument("--bank", required=True)
    ap.add_argument("--corr", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--reject", action="append", default=[], metavar="SEX:TRAIT:TYPE",
                    help="a type judged wrong by eye (e.g. female:nose:E): kept in the file, flagged, never drawn")
    ap.add_argument("--cover", type=float, default=COVER, help="the share of a band's photos its kept types cover")
    ap.add_argument("--origin", default="European", help="the photos' origin, as the file's doc names it")
    ap.add_argument("--min-photos", type=int, default=MIN_PHOTOS, help="a sex's fewest fitted photos to learn its types")
    ap.add_argument("--fit-bias", help="fit_bias.py's JSON: what the fit adds to a face, per sex (stored values), "
                                       "taken off every photo's weights")
    a = ap.parse_args()
    photos = {p["path"]: p for p in json.load(open(os.path.expanduser(a.photos)))}
    rows = []
    for f in sorted(glob.glob(os.path.expanduser(a.fits))):
        for line in open(f):
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue  # a line still being written
            if r.get("found", True) and r["path"] in photos:
                rows.append(r)
    rms = np.array([r["rms"] for r in rows])
    rows = [r for r, e in zip(rows, rms) if e <= np.quantile(rms, 1.0 - WORST_FITS)]
    keys = sorted({k for r in rows for k in r["weights"]})
    stats = json.load(open(FACE_STATS)).get("sliders", {})
    reach = np.array([FLAME_RANGE if k.startswith(FLAME_PREFIX) else float(stats.get(k, {}).get("range", 1.0)) for k in keys])
    stored = np.array([[r["weights"].get(k, 0.0) for k in keys] for r in rows])
    w = stored * reach  # shape-key weights
    female = np.array([photos[r["path"]]["female"] for r in rows])
    years = np.array([photos[r["path"]]["years"] for r in rows])
    if a.fit_bias:
        # The fit's own lean, measured on renders of known faces: off every photo, so the mean face is the photos'
        # (the types, made of differences between photos, are left as they were).
        bias = json.load(open(os.path.expanduser(a.fit_bias)))
        for sex, mask in (("female", female), ("male", ~female)):
            off = np.array([float(bias.get(sex, {}).get(k, 0.0)) for k in keys]) * reach
            w[mask] -= off
        print("fit bias taken off:", {sx: round(float(np.sqrt(sum(v * v for v in b.values()))), 3) for sx, b in bias.items()})
    neutral = np.array([photos[r["path"]].get("smile", 0.0) < MAX_SMILE
                        and r.get("expression", {}).get("FACS_Mouth_Large_Opened", 0.0) < MAX_MOUTH_OPEN for r in rows])
    bank = Bank(os.path.expanduser(a.bank))
    corr = np.load(os.path.expanduser(a.corr))
    A = np.stack([sample(bank.target(k), corr) for k in keys], -1) * 1000.0  # (478, 3, K) mm per unit weight
    head = sample(bank.base, corr)
    parts = regions(head)
    print(f"{len(rows)} photos fitted ({int(female.sum())} women), {int(neutral.sum())} without a marked smile; {len(keys)} keys")
    out = {
        "_doc": "Generated by tools/character/face_survey/face_types.py from FFHQ's %s adults. Never edit by hand." % a.origin,
        "origin": a.origin,
        "source": "FFHQ (NVIDIA, CC BY-NC-SA 4.0) and its labels (DCGM/ffhq-features-dataset, CC BY-NC-SA 4.0); origin "
                  "read by FairFace (Karkkainen & Joo, CC BY 4.0). Means of at least %d faces each." % MIN_GROUP,
        "traits": TRAITS,
    }
    rng = np.random.default_rng(a.seed)
    for sex, mask in (("female", female), ("male", ~female)):
        if mask.sum() < a.min_photos:
            print(f"{sex}: {int(mask.sum())} photos, under {a.min_photos}: left out")
            continue
        base_set = mask & neutral
        own = np.array([k.startswith(FLAME_PREFIX) or k in JAW_KEYS or k in NOSE_KEYS for k in keys])
        cov = np.cov(w[mask][:, own].T) + COVARIANCE_FLOOR * np.eye(int(own.sum()))
        cov_inv = np.linalg.inv(cov)
        Aall = A.reshape(-1, len(keys))
        mean_w = np.zeros(len(keys))  # the mean face's shape, made of the own keys
        mean_w[own] = np.linalg.solve(Aall[:, own].T @ Aall[:, own] / LANDMARK_NOISE + MEAN_PRIOR * cov_inv,
                                      Aall[:, own].T @ (Aall @ w[base_set].mean(0)) / LANDMARK_NOISE)
        flame_rows = np.array([k.startswith(FLAME_PREFIX) for k in keys])
        draws = np.random.default_rng(7).standard_normal((2000, len(keys))) * flame_rows  # random()'s faces
        sex_out = {"mean": {}, "noise": {}, "traits": {}}
        offsets = np.zeros_like(w[mask])  # per photo of this sex: the types' offsets it is given
        for trait in TRAITS:
            idx = parts[trait]
            rest = [i for i in range(478) if i not in idx]
            Ar = A[idx].reshape(-1, len(keys))
            Ao = A[rest].reshape(-1, len(keys))
            subset = (mask & neutral) if trait in NEUTRAL_TRAITS else mask
            shape = (w @ Ar.T)  # (n, 3*|idx|) every photo's trait, mm
            centre = shape[subset].mean(0)
            spread_photos = np.sqrt(((shape[subset] - centre) ** 2).sum(1).mean())
            spread_random = np.sqrt(((draws @ Ar.T) ** 2).sum(1).mean())
            x = shape - centre
            u, s, vt = np.linalg.svd(x[subset], full_matrices=False)
            keep = min(MAX_COMPONENTS, int(np.searchsorted(np.cumsum(s ** 2) / (s ** 2).sum(), COMPONENTS)) + 1)
            proj = x @ vt[:keep].T
            k = TYPES
            while True:
                label, centres = kmeans(proj[subset], k, rng)
                sizes = np.bincount(label, minlength=k)
                if sizes.min() >= MIN_GROUP or k == 2:
                    break
                k -= 1
            again, _ = kmeans(proj[subset], k, np.random.default_rng(a.seed + 100))
            order = np.argsort(-sizes)
            centres, sizes = centres[order], sizes[order]
            label = np.argsort(order)[label]
            rejected = [t for t in range(k) if f"{sex}:{trait}:{chr(ord('A') + t)}" in a.reject]
            far = ((proj[:, None, :] - centres[None]) ** 2).sum(-1)
            far[:, rejected] = np.inf
            every = far.argmin(1)  # every photo's nearest type (a rejected one's photos: the nearest kept)
            normal = Ar[:, own].T @ Ar[:, own] / LANDMARK_NOISE + cov_inv
            types = []
            for t in range(k):
                d = centres[t] @ vt[:keep]  # the type's mean shape, from the trait's mean (mm)
                delta = np.zeros(len(keys))
                delta[own] = np.linalg.solve(normal, Ar[:, own].T @ d / LANDMARK_NOISE)
                made = Ar @ delta
                types.append({"id": chr(ord("A") + t), "size": int(sizes[t]), **({"rejected": True} if t in rejected else {}),
                              "made": round(float(np.linalg.norm(made - d) / max(np.linalg.norm(d), 1e-9)), 3),
                              "spill_mm": round(float(np.sqrt(((Ao @ delta) ** 2).mean())), 3),
                              "delta": {kk: round(float(v / r), 4) for kk, v, r in zip(keys, delta, reach)
                                        if abs(v / r) >= SMALLEST},
                              "_delta": delta})
            bands, counts = merged_bands(years[subset])
            band_out = []
            for b, (lo, hi) in enumerate(bands):
                inside = np.array([band_of(y, bands) == b for y in years[subset]])
                share = np.bincount(label[inside], minlength=k) / max(inside.sum(), 1)
                share[rejected] = 0.0  # never kept: the next most frequent type takes its place
                share /= max(share.sum(), 1e-12)
                order = np.argsort(-share, kind="stable")
                count = int(np.searchsorted(np.cumsum(share[order]), a.cover - 1e-9)) + 1
                top = order[:min(count, int((share > 0).sum()))]
                total = share[top].sum()
                band_out.append({"from": lo, "to": hi, "photos": int(inside.sum()), "cover": round(float(total), 3),
                                 "types": [[int(t), round(float(share[t] / total), 3)] for t in top]})
            for i_local, i in enumerate(np.where(mask)[0]):
                offsets[i_local] += types[every[i]]["_delta"]
            sex_out["traits"].setdefault(trait, {})
            shrink = round(float(spread_photos / spread_random), 3)
            sizes_mm = [round(float(np.linalg.norm(c @ vt[:keep])), 1) for c in centres]
            print(f"{sex:6s} {trait:5s} shrink {shrink:.2f}, types' spread {sizes_mm} mm "
                  f"(photos' {spread_photos:.1f}, random's {spread_random:.1f})")
            print(f"{sex:6s} {trait:5s} {keep:2d} components, {k} types {[ty['size'] for ty in types]}, "
                  f"stable {agreement(label, again, k) if len(set(again)) == k else 0:.0%}, made "
                  f"{[ty['made'] for ty in types]}, spill {[ty['spill_mm'] for ty in types]} mm")
            for bo in band_out:
                print(f"         {bo['from']:2d}-{bo['to']:2d} ({bo['photos']:4d}, cover {bo['cover']:.0%}): " + ", ".join(
                    f"{types[t]['id']} {s:.0%}" for t, s in bo["types"]))
            for ty in types:
                del ty["_delta"]
            sex_out["traits"][trait] = {"types": types, "bands": band_out, "shrink": shrink}
        # The types of one face add up, and each carries what its trait comes with in real faces: summed, they may
        # count those twice. The gain brings their summed spread down to the fitted faces' own (never up).
        gain = min(1.0, float(np.sqrt(w[mask].var(0).sum() / max(offsets.var(0).sum(), 1e-12))))
        sex_out["gain"] = round(gain, 3)
        typed = offsets.var(0) * gain ** 2  # what the types spread along each key (shape-key units squared)
        sex_out["mean"] = {k: round(float(v / r), 4) for k, v, r in zip(keys, mean_w, reach) if abs(v / r) >= SMALLEST}
        sex_out["noise"] = {k: round(float(np.sqrt(max(1.0 - typed[j], 0.25)) / reach[j]), 4) for j, k in enumerate(keys)
                            if k.startswith(FLAME_PREFIX)}
        flame = [j for j, k in enumerate(keys) if k.startswith(FLAME_PREFIX)]
        print(f"{sex}: gain {gain:.2f}; FLAME spread of the fits {w[mask][:, flame].std(0).mean():.2f}, of the types "
              f"{np.sqrt(typed[flame]).mean():.2f} (max {np.sqrt(typed[flame]).max():.2f}); random() draws 1.00")
        out[sex] = sex_out
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    print("wrote", a.out)


if __name__ == "__main__":
    sys.exit(main())
