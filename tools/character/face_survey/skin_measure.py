#!/usr/bin/env python3
"""A few numbers about a face's skin, measured on a photo -- to learn TENDENCIES (how wrinkles grow with
age, who has freckles), never to copy a skin. Patches are placed by MediaPipe's landmarks and sized by the
distance between the eyes (IOD), so they land on the same anatomy whatever the photo.

    python skin_measure.py <landmarks.npz> <out.npz> [--workers 6]

Per face (all relative: the light of a photo is unknown, so a patch is compared with another patch):
  ita          Individual Typology Angle of the cheeks (deg): high = fair, low = dark skin
  redness      a* of the cheeks minus a* of the forehead (Lab)
  nose_red     a* of the nose's tip minus a* of the forehead
  eye_bags     L* under the eyes minus L* of the cheeks (negative = darker)
  freckles     small dark spots per cm^2-equivalent on the nose's bridge and the cheeks
  moles        larger dark spots over the whole face
  forehead     energy of horizontal creases on the forehead (normalised by the patch's contrast)
  crows_feet   energy of creases beside the eyes' outer corners
  uneven       spread of the cheeks' and forehead's lightness once the light's gradient is removed

Needs opencv (cv2) and numpy: run with the MediaPipe venv.
"""
import argparse
import sys
from concurrent.futures import ProcessPoolExecutor

import cv2
import numpy as np

# MediaPipe face mesh landmark indices.
LEFT_EYE_OUT, RIGHT_EYE_OUT = 33, 263
LEFT_EYE_IN, RIGHT_EYE_IN = 133, 362
FOREHEAD = 151
NOSE_BRIDGE = 6
NOSE_TIP = 4
LEFT_CHEEK, RIGHT_CHEEK = 205, 425
LEFT_UNDER_EYE, RIGHT_UNDER_EYE = 230, 450
CHIN = 152
MEASURES = ("ita", "redness", "nose_red", "eye_bags", "freckles", "moles", "forehead", "crows_feet", "uneven")


def patch(image, centre, half):
    x, y = int(round(centre[0])), int(round(centre[1]))
    h = max(int(round(half)), 2)
    if x - h < 0 or y - h < 0 or x + h >= image.shape[1] or y + h >= image.shape[0]:
        return None
    return image[y - h:y + h, x - h:x + h]


def lab_of(bgr):
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    return lab[..., 0] * (100.0 / 255.0), lab[..., 1] - 128.0, lab[..., 2] - 128.0


def flat(lightness):
    """Lightness with its linear gradient (the light across the patch) removed."""
    h, w = lightness.shape
    yy, xx = np.mgrid[0:h, 0:w]
    a = np.stack([xx.ravel(), yy.ravel(), np.ones(h * w)], 1)
    coef, *_ = np.linalg.lstsq(a, lightness.ravel(), rcond=None)
    return (lightness - (a @ coef).reshape(h, w)).astype(np.float32)


def spots(lightness, sigma, contrast):
    """Count of dark blobs of about this size (difference of Gaussians), at least `contrast` L* deep."""
    g1 = cv2.GaussianBlur(lightness, (0, 0), sigma)
    g2 = cv2.GaussianBlur(lightness, (0, 0), sigma * 3.0)
    dog = g2 - g1  # positive where darker than around
    peaks = (dog > contrast) & (dog == cv2.dilate(dog, np.ones((3, 3), np.uint8)))
    return int(peaks.sum())


def crease_energy(lightness, sigma, horizontal):
    """How much more the lightness changes ACROSS one direction than along it (L* per pixel, at a blur
    scaled to the face): creases running that way. Pores and noise change it equally both ways."""
    smooth = cv2.GaussianBlur(flat(lightness), (0, 0), sigma)
    gy = cv2.Sobel(smooth, cv2.CV_32F, 0, 1, ksize=3)
    gx = cv2.Sobel(smooth, cv2.CV_32F, 1, 0, ksize=3)
    across, along = (gy, gx) if horizontal else (gx, gy)
    return float(np.sqrt((across ** 2).mean()) - np.sqrt((along ** 2).mean()))


def measure(job):
    path, lm = job
    image = cv2.imread(path)
    if image is None:
        return None
    h, w = image.shape[:2]
    p = lm[:, :2] * np.array([w, h])
    iod = float(np.linalg.norm(p[LEFT_EYE_OUT] - p[RIGHT_EYE_OUT]))
    if iod < 40:
        return None
    s = iod / 9.0  # pixels per cm: the eyes' outer corners are ~9 cm apart on an adult
    out = {}
    cheeks = [patch(image, p[i], iod * 0.11) for i in (LEFT_CHEEK, RIGHT_CHEEK)]
    forehead = patch(image, p[FOREHEAD] + np.array([0.0, -iod * 0.05]), iod * 0.16)
    nose = patch(image, p[NOSE_TIP], iod * 0.06)
    bridge = patch(image, p[NOSE_BRIDGE] + (p[NOSE_TIP] - p[NOSE_BRIDGE]) * 0.35, iod * 0.07)
    under = [patch(image, p[i] + np.array([0.0, iod * 0.03]), iod * 0.06) for i in (LEFT_UNDER_EYE, RIGHT_UNDER_EYE)]
    crows = [patch(image, p[i] + np.array([sgn * iod * 0.12, 0.0]), iod * 0.08) for i, sgn in ((LEFT_EYE_OUT, -1), (RIGHT_EYE_OUT, 1))]
    if any(x is None for x in cheeks + under + crows) or forehead is None or nose is None or bridge is None:
        return None
    cl = [lab_of(c) for c in cheeks]
    fl, fa, _fb = lab_of(forehead)
    cheek_l = np.concatenate([c[0].ravel() for c in cl])
    cheek_a = np.concatenate([c[1].ravel() for c in cl])
    cheek_b = np.concatenate([c[2].ravel() for c in cl])
    lmed, bmed = float(np.median(cheek_l)), float(np.median(cheek_b))
    out["ita"] = float(np.degrees(np.arctan2(lmed - 50.0, max(bmed, 1e-3))))
    out["redness"] = float(np.median(cheek_a) - np.median(fa))
    out["nose_red"] = float(np.median(lab_of(nose)[1]) - np.median(fa))
    out["eye_bags"] = float(np.mean([np.median(lab_of(u)[0]) for u in under]) - lmed)
    area_cm2 = sum(c.shape[0] * c.shape[1] for c in cheeks + [bridge]) / (s * s)
    out["freckles"] = sum(spots(lab_of(c)[0], max(s * 0.06, 0.8), 3.0) for c in cheeks + [bridge]) / area_cm2
    face = patch(image, (p[NOSE_BRIDGE] + p[CHIN]) * 0.5, iod * 0.55)
    out["moles"] = float(spots(lab_of(face)[0], max(s * 0.2, 1.5), 9.0)) if face is not None else np.nan
    out["forehead"] = crease_energy(fl, max(s * 0.03, 0.7), horizontal=True)
    out["crows_feet"] = float(np.mean([crease_energy(lab_of(c)[0], max(s * 0.03, 0.7), horizontal=True) for c in crows]))
    out["uneven"] = float(np.std(np.concatenate([flat(cl[0][0]).ravel(), flat(cl[1][0]).ravel(),
                                                  flat(cv2.resize(fl, (cl[0][0].shape[1], cl[0][0].shape[0]))).ravel()])))
    return np.array([out[m] for m in MEASURES], dtype=np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("landmarks")
    ap.add_argument("out")
    ap.add_argument("--workers", type=int, default=1,
                    help="processes; 1 = plain loop (several ate the machine's memory: keep 1 unless watched)")
    args = ap.parse_args()
    marks = np.load(args.landmarks, allow_pickle=True)
    # Read each array ONCE: an .npz member is read (and decompressed) again at every marks["..."], and a row
    # of it keeps the whole array alive -- 9 000 of those took the machine's memory.
    points, paths = marks["points"], marks["paths"]
    jobs = [(str(p), points[k].copy()) for k, p in enumerate(paths)]
    rows, kept = [], []
    cv2.setNumThreads(1)
    if args.workers <= 1:
        results = map(measure, jobs)
    else:
        pool = ProcessPoolExecutor(args.workers)
        results = pool.map(measure, jobs, chunksize=32)
    for k, row in enumerate(results):
        if row is not None:
            rows.append(row)
            kept.append(jobs[k][0])
        if (k + 1) % 1000 == 0:
            print(f"{k + 1}/{len(jobs)}", flush=True)
    np.savez_compressed(args.out, paths=np.array(kept), values=np.array(rows), measures=np.array(MEASURES))
    print(f"{len(rows)} faces measured of {len(jobs)} -> {args.out}")


if __name__ == "__main__":
    sys.exit(main())
