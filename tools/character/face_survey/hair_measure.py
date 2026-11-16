#!/usr/bin/env python3
"""What hair people wear, measured on photos (or on our renders, to compare) -- to learn TENDENCIES (how long, how
curly, who has a fringe, how hairlines recede with age), never to copy a person's hair.

    python hair_measure.py <segmenter.tflite> <landmarks.npz> <features dir|-> <out.npz> [--count 8000]
    python hair_measure.py --summary <out.npz>

The hair is MediaPipe's multiclass selfie segmenter's "hair" class; the face is placed by MediaPipe's face landmarks
and everything is measured in IOD (the distance between the irises' centres), so a measure lands on the same anatomy
whatever the photo. Heads turned aside are kept on purpose: a profile shows the length and the volume at the back.
Beards are not in the segmenter's hair class: they come from ffhq-features' facialHair scores (Azure Face API).

Per photo (the measure's name, then what it is):
  yaw, pitch       head pose (deg; ffhq-features, else 0)
  amount           hair area / IOD^2
  crown            height of the hair's top above the brows' line / IOD
  forehead         bare forehead on the face's midline, from the brows' line up to the hair / IOD (large = high
                   hairline or bald; tiny = a fringe)
  fringe           share of the forehead box (between the brows' outer ends, from their line up 0.9 IOD) under hair
  fringe_side      fringe's left-right imbalance, -1..1 (a fringe swept to one side)
  temples          bare forehead at the temples minus on the midline / IOD (receding temples: > 0)
  below_chin       lowest hair below the chin / IOD (negative = it ends above the chin)
  cropped          1 if the hair runs off the photo's bottom edge (its length is then a lower bound)
  width            widest hair from the ear level up, over the face's width (cheek to cheek)
  coherence        median coherence of the hair's texture (structure tensor at ~0.04 IOD): 1 = straight lines,
                   low = curls and coils
  hair_rgb         median linear RGB of the hair (highlights dropped); skin_rgb the face's, to compare
  bald, moustache, beard, sideburns, age, male   ffhq-features (Azure Face API) when given
Needs opencv (cv2), numpy and mediapipe: run with the MediaPipe venv.
"""
import argparse
import json
import os
import sys

import cv2
import numpy as np

HAIR, BODY, FACE, CLOTHES = 1, 2, 3, 4
EYE_L, EYE_R = 468, 473
BROW_L, BROW_R = 105, 334  # the brows' tops
BROW_OUT_L, BROW_OUT_R = 70, 300  # their outer ends
CHIN = 152
CHEEK_L, CHEEK_R = 234, 454
EAR_L, EAR_R = 132, 361  # the jaw's back, about the ear lobes' height
MEASURES = ("yaw", "pitch", "amount", "crown", "forehead", "fringe", "fringe_side", "temples", "below_chin", "cropped",
            "width", "coherence", "bald", "moustache", "beard", "sideburns", "age", "male")


def linear(srgb):
    s = srgb.astype(np.float64) / 255.0
    return np.where(s <= 0.04045, s / 12.92, ((s + 0.055) / 1.055) ** 2.4)


def bare_above(hair, x, y_from, limit):
    """Pixels from y_from upwards at column x until hair (or limit pixels)."""
    col = hair[max(0, int(y_from) - int(limit)):int(y_from), int(x)][::-1]
    hits = np.nonzero(col)[0]
    return float(hits[0]) if len(hits) else float(limit)


def measure(image, mask, pts):
    h, w = mask.shape
    p = pts[:, :2] * (w, h)
    iod = float(np.linalg.norm(p[EYE_L] - p[EYE_R]))
    if iod < 20:
        return None
    hair = mask == HAIR
    out = {}
    out["amount"] = hair.sum() / iod ** 2
    brow_y = 0.5 * (p[BROW_L, 1] + p[BROW_R, 1])
    mid_x = 0.5 * (p[BROW_L, 0] + p[BROW_R, 0])
    rows = np.nonzero(hair.any(1))[0]
    out["crown"] = (brow_y - rows[0]) / iod if len(rows) else 0.0
    out["below_chin"] = (rows[-1] - p[CHIN, 1]) / iod if len(rows) else -9.0
    out["cropped"] = float(len(rows) > 0 and rows[-1] >= h - 2)
    limit = 2.5 * iod
    mid = bare_above(hair, mid_x, brow_y, limit)
    out["forehead"] = mid / iod
    sides = [bare_above(hair, mid_x + s * 0.75 * iod, brow_y, limit) for s in (-1.0, 1.0)]
    out["temples"] = (np.mean(sides) - mid) / iod
    x0, x1 = int(min(p[BROW_OUT_L, 0], p[BROW_OUT_R, 0])), int(max(p[BROW_OUT_L, 0], p[BROW_OUT_R, 0]))
    y0, y1 = int(max(0, brow_y - 0.9 * iod)), int(brow_y - 0.08 * iod)
    box = hair[y0:y1, x0:x1]
    out["fringe"] = float(box.mean()) if box.size else 0.0
    half = box.shape[1] // 2
    left, right = (box[:, :half].mean(), box[:, half:].mean()) if half > 0 else (0.0, 0.0)
    out["fringe_side"] = float((right - left) / max(left + right, 1e-6)) if left + right > 0.05 else 0.0
    ear_y = int(0.5 * (p[EAR_L, 1] + p[EAR_R, 1]))
    cols = np.nonzero(hair[:max(ear_y, 1)].any(0))[0]
    face_w = float(np.linalg.norm(p[CHEEK_L] - p[CHEEK_R]))
    out["width"] = (cols[-1] - cols[0]) / face_w if len(cols) else 0.0
    # Texture: the structure tensor's coherence inside the hair (eroded so the outline does not count).
    grey = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    sigma = max(1.0, 0.04 * iod)
    gx = cv2.Sobel(grey, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(grey, cv2.CV_32F, 0, 1, ksize=3)
    jxx = cv2.GaussianBlur(gx * gx, (0, 0), sigma)
    jyy = cv2.GaussianBlur(gy * gy, (0, 0), sigma)
    jxy = cv2.GaussianBlur(gx * gy, (0, 0), sigma)
    root = np.sqrt((jxx - jyy) ** 2 + 4.0 * jxy ** 2)
    coh = root / np.maximum(jxx + jyy, 1e-6)
    inner = cv2.erode(hair.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=max(1, int(0.08 * iod))).astype(bool)
    textured = inner & ((jxx + jyy) > 1e-4)  # flat (blown-out or black) hair tells nothing
    out["coherence"] = float(np.median(coh[textured])) if textured.sum() > 200 else np.nan
    lin = linear(image[:, :, ::-1])
    lum = lin @ (0.2126, 0.7152, 0.0722)

    def median_colour(sel):
        if sel.sum() < 100:
            return np.full(3, np.nan)
        keep = sel & (lum <= np.quantile(lum[sel], 0.85))
        return np.median(lin[keep], axis=0)

    out["hair_rgb"] = median_colour(inner)
    out["skin_rgb"] = median_colour(mask == FACE)
    return out


def features_of(features, path):
    if features in (None, "-"):
        return {}
    f = os.path.join(features, os.path.basename(str(path))[:5] + ".json")
    if not os.path.exists(f):
        return None
    data = json.load(open(f))
    if not data:
        return None
    fa = data[0]["faceAttributes"]
    if any(a.get("type") == "headwear" for a in fa.get("accessories", [])):
        return None  # a hat hides the hair
    pose = fa.get("headPose", {})
    fh = fa.get("facialHair", {})
    return {"yaw": pose.get("yaw", 0.0), "pitch": pose.get("pitch", 0.0), "bald": fa.get("hair", {}).get("bald", np.nan),
            "moustache": fh.get("moustache", np.nan), "beard": fh.get("beard", np.nan), "sideburns": fh.get("sideburns", np.nan),
            "age": fa.get("age", np.nan), "male": 1.0 if fa.get("gender") == "male" else 0.0}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("segmenter")
    ap.add_argument("landmarks")
    ap.add_argument("features")
    ap.add_argument("out")
    ap.add_argument("--count", type=int, default=8000)
    args = ap.parse_args()
    import mediapipe as mp
    from mediapipe.tasks import python as mpt
    from mediapipe.tasks.python import vision
    seg = vision.ImageSegmenter.create_from_options(vision.ImageSegmenterOptions(
        base_options=mpt.BaseOptions(model_asset_path=args.segmenter), output_category_mask=True))
    z = np.load(args.landmarks, allow_pickle=True)
    paths, points = z["paths"], z["points"]  # each read once
    order = np.random.default_rng(2).permutation(len(paths))[:args.count]
    rows, colours, kept = [], [], []
    for n, i in enumerate(order):
        feats = features_of(args.features, paths[i])
        if feats is None:
            continue
        image = cv2.imread(str(paths[i]))
        if image is None:
            continue
        mask = seg.segment(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(image, cv2.COLOR_BGR2RGB)))
        mask = mask.category_mask.numpy_view()
        mask = mask[:, :, 0] if mask.ndim == 3 else mask
        m = measure(image, mask, points[i])
        if m is None:
            continue
        m.update(feats)
        rows.append([float(m.get(k, np.nan)) for k in MEASURES])
        colours.append(np.concatenate([m["hair_rgb"], m["skin_rgb"]]))
        kept.append(i)
        if n % 500 == 0:
            print(f"{n}/{len(order)}", file=sys.stderr, flush=True)
    rows = np.array(rows)
    np.savez(args.out, rows=rows, colours=np.array(colours), index=np.array(kept), columns=np.array(MEASURES))
    summarise(rows)


def summarise(rows):
    col = {k: rows[:, j] for j, k in enumerate(MEASURES)}

    def q(v):
        v = v[np.isfinite(v)]
        return " / ".join(f"{x:6.2f}" for x in np.percentile(v, [10, 50, 90])) + f"  (n={len(v)})"

    print(f"{len(rows)} photos (10th / median / 90th percentile)")
    groups = ((1.0, "men"), (0.0, "women")) if np.isfinite(col["male"]).any() else ((None, "all"),)
    for sex, name in groups:
        s = col["male"] == sex if sex is not None else np.ones(len(rows), bool)
        print(f"-- {name}")
        for k in ("amount", "crown", "forehead", "fringe", "temples", "below_chin", "width", "coherence"):
            print(f"  {k:11s} {q(col[k][s])}")
        print(f"  cropped     {np.nanmean(col['cropped'][s]):.2f}   fringe > 0.5: {np.nanmean(col['fringe'][s] > 0.5):.2f}")
        if sex == 1.0:
            print(f"  beard > 0.5 {np.nanmean(col['beard'][s] > 0.5):.2f}   moustache > 0.5 {np.nanmean(col['moustache'][s] > 0.5):.2f}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--summary":
        summarise(np.load(sys.argv[2])["rows"])
    else:
        main()
