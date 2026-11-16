#!/usr/bin/env python3
"""A few numbers about the eyes, measured on photos (or on our renders, to compare): how dark the white of
the eye is against the skin, the iris' colour against that white, the limbal ring, how much of the iris the
lids hide. Never per person: the summary is the spread over many faces.

    python eye_measure.py <landmarks.npz> <out.npz> [--mask neutral_mask.npy] [--count 3000]

The eye's opening is MediaPipe's eye contour pulled in a little (it runs on the lids' margins); the iris is
found again on the pixels (MediaPipe's iris landmarks are only a start): the circle across whose lateral arcs
the light jumps the most -- Daugman's operator -- the lids hiding its top and bottom.
Per eye, in linear RGB (the photo's light is unknown, so colours are compared with each other):
  iris         mean of the iris between 0.45 and 0.85 of its radius (the pupil and the rim left out), its
               brightest tenth dropped (catch-lights)
  rim          mean of the iris' lateral arcs between 0.85 and 1.0 of its radius: rim / iris = the limbal ring
  sclera       mean of the opening's pixels outside 1.15 iris radii between its median and its 95th
               percentile of light: the lit white, not the lashes and the lid's shade
  skin         mean of a patch under the eye
  shown        visible height of the opening over the iris' diameter (1 = the lids just touch the iris)
  iris_width   the iris' diameter over the eye's width (corner to corner)

Needs opencv (cv2) and numpy: run with the MediaPipe venv.
"""
import argparse
import sys

import cv2
import numpy as np

EYES = (  # (contour, iris centre, iris rim, under-eye skin)
    ([33, 246, 161, 160, 159, 158, 157, 173, 133, 155, 154, 153, 145, 144, 163, 7], 468, (469, 470, 471, 472), 230),
    ([263, 466, 388, 387, 386, 385, 384, 398, 362, 382, 381, 380, 374, 373, 390, 249], 473, (474, 475, 476, 477), 450),
)
UPPER = {33: 159, 263: 386}
LOWER = {33: 145, 263: 374}


def linear(srgb):
    s = srgb.astype(np.float64) / 255.0
    return np.where(s <= 0.04045, s / 12.92, ((s + 0.055) / 1.055) ** 2.4)


def find_iris(lum, c, radius):
    """(centre, radius) of the iris near MediaPipe's guess: the strongest dark-to-light jump across the
    circle's lateral arcs (Daugman's integro-differential operator)."""
    angles = np.radians(np.concatenate([np.linspace(-35, 35, 15), np.linspace(145, 215, 15)]))
    radii = np.linspace(0.6, 1.35, 31) * radius
    step = max(1.0, radius * 0.04)
    span = np.arange(-0.25 * radius, 0.25 * radius + 1e-6, step)
    best = (-1.0, c, radius)
    for dy in span:
        for dx in span:
            cx, cy = c[0] + dx, c[1] + dy
            mx = (cx + radii[:, None] * np.cos(angles)[None]).astype(np.float32)
            my = (cy + radii[:, None] * np.sin(angles)[None]).astype(np.float32)
            ring = cv2.remap(lum.astype(np.float32), mx, my, cv2.INTER_LINEAR).mean(1)
            jump = np.convolve(np.diff(ring), np.ones(3) / 3.0, "same")
            k = int(np.argmax(jump))
            if jump[k] > best[0]:
                best = (jump[k], np.array([cx, cy]), 0.5 * (radii[k] + radii[k + 1]))
    return best[1], best[2]


def measure(image, pts, debug=None):
    """Per eye: iris, rim, sclera, skin (linear RGB), shown, iris_width -- or None when unusable."""
    h, w = image.shape[:2]
    p = pts[:, :2] * (w, h)
    lin = linear(image[:, :, ::-1])  # BGR -> RGB
    lum = lin @ (0.2126, 0.7152, 0.0722)
    yy, xx = np.mgrid[0:h, 0:w]
    out = []
    for contour, centre, rim_ids, under in EYES:
        poly = p[contour].astype(np.int32)
        x0, y0 = poly.min(0) - 2
        x1, y1 = poly.max(0) + 3
        if x0 < 0 or y0 < 0 or x1 >= w or y1 >= h:
            return None
        guess = np.mean(np.linalg.norm(p[list(rim_ids)] - p[centre], axis=1))
        c, radius = find_iris(lum, p[centre], guess)
        mask = np.zeros((h, w), np.uint8)
        cv2.fillPoly(mask, [poly], 1)
        mask = cv2.erode(mask, np.ones((3, 3), np.uint8), iterations=max(1, int(round(radius * 0.12))))
        box = (slice(y0, y1), slice(x0, x1))
        inside = mask[box].astype(bool)
        r = np.hypot(xx[box] - c[0], yy[box] - c[1]) / radius
        lateral = np.abs(yy[box] - c[1]) < 0.55 * radius
        if debug is not None:
            cv2.polylines(debug, [poly], True, (0, 255, 0), 1)
            cv2.circle(debug, (int(c[0]), int(c[1])), int(radius), (0, 0, 255), 1)
        colours, lums = lin[box], lum[box]

        def mean_of(sel, low, high):
            if sel.sum() < 12:
                return None
            v, l = colours[sel], lums[sel]
            keep = (l >= np.quantile(l, low)) & (l <= np.quantile(l, high))
            return v[keep].mean(0)

        iris = mean_of(inside & (r > 0.45) & (r < 0.85), 0.0, 0.9)
        rim = mean_of(inside & lateral & (r > 0.85) & (r < 1.0), 0.0, 0.9)
        sclera = mean_of(inside & (r > 1.15), 0.5, 0.95)
        if iris is None or rim is None or sclera is None:
            return None
        s = p[under]
        half = max(2, int(radius * 0.6))
        sy, sx = int(s[1] + radius * 0.6), int(s[0])
        skin = lin[sy - half:sy + half, sx - half:sx + half].reshape(-1, 3).mean(0)
        width = np.linalg.norm(p[contour[0]] - p[contour[8]])
        shown = (p[LOWER[contour[0]], 1] - p[UPPER[contour[0]], 1]) / (2.0 * radius)
        out.append((iris, rim, sclera, skin, shown, 2.0 * radius / width))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("landmarks")
    ap.add_argument("out")
    ap.add_argument("--mask", help="bool .npy: the photos to measure (e.g. neutral faces)")
    ap.add_argument("--count", type=int, default=3000)
    args = ap.parse_args()
    z = np.load(args.landmarks, allow_pickle=True)
    paths, points, scores = z["paths"], z["points"], z["scores"]  # each read once
    names = [str(n) for n in z["blendshape_names"]]
    usable = np.ones(len(paths), bool) if not args.mask else np.load(args.mask)
    for key in ("eyeBlinkLeft", "eyeBlinkRight", "eyeSquintLeft", "eyeSquintRight"):
        usable &= scores[:, names.index(key)] < 0.35
    for key in ("eyeLookUpLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft"):
        usable &= scores[:, names.index(key)] < 0.4
    chosen = np.where(usable)[0]
    chosen = chosen[np.random.default_rng(1).permutation(len(chosen))[:args.count]]
    rows, kept = [], []
    for n, i in enumerate(chosen):
        image = cv2.imread(str(paths[i]))
        if image is None:
            continue
        m = measure(image, points[i])
        if m is None:
            continue
        for iris, rim, sclera, skin, shown, iris_width in m:
            rows.append(np.concatenate([iris, rim, sclera, skin, [shown, iris_width]]))
            kept.append(i)
        if n % 500 == 0:
            print(f"{n}/{len(chosen)}", file=sys.stderr)
    rows = np.array(rows)
    np.savez(args.out, rows=rows, index=np.array(kept),
             columns=np.array(["iris"] * 3 + ["rim"] * 3 + ["sclera"] * 3 + ["skin"] * 3 + ["shown", "iris_width"]))
    summarise(rows)


def summarise(rows):
    iris, rim, sclera, skin = rows[:, 0:3], rows[:, 3:6], rows[:, 6:9], rows[:, 9:12]
    y = np.array([0.2126, 0.7152, 0.0722])

    def q(v):
        return " / ".join(f"{x:.3f}" for x in np.percentile(v, [10, 50, 90]))

    print(f"{len(rows)} eyes (10th / median / 90th percentile)")
    print(f"  sclera / skin luminance   {q(sclera @ y / np.maximum(skin @ y, 1e-4))}")
    print(f"  sclera chroma r/g, b/g    {q(sclera[:, 0] / sclera[:, 1])}   {q(sclera[:, 2] / sclera[:, 1])}")
    print(f"  iris / sclera luminance   {q(iris @ y / np.maximum(sclera @ y, 1e-4))}")
    print(f"  rim / iris luminance      {q(rim @ y / np.maximum(iris @ y, 1e-4))}")
    print(f"  shown (opening / iris)    {q(rows[:, 12])}")
    print(f"  iris diameter / eye width {q(rows[:, 13])}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--summary":
        summarise(np.load(sys.argv[2])["rows"])
    else:
        main()
