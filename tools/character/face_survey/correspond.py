#!/usr/bin/env python3
"""Where each MediaPipe landmark lies on the Vitruvian head: once, from renders of the neutral head.

    python3 correspond.py <human_bank.npz> <landmarks.npz of the neutral render(s)> <out.npz>

The neutral head is rendered front-on through an orthographic camera (render_heads.tscn, which writes the
camera beside each PNG), so a landmark's pixel is a point (x, y) in the bank's space: the landmark is where
a ray along -z from there first meets the head. Kept as a triangle of compact vertices and its barycentric
weights, so that it follows any face shape. Also reports how MediaPipe's own depth compares with ours.
"""
import json
import os
import sys

import numpy as np

HEAD_ZONES = ("Face", "Iris", "Pupil", "Sclera_Cornea")


def head_triangles(bank):
    zones = [str(z) for z in bank["zone_names"]]
    vptr, iptr = bank["zone_vertex_ptr"], bank["zone_index_ptr"]
    tris = []
    for name in HEAD_ZONES:
        z = zones.index(name)
        local = bank["body_index"][iptr[z]:iptr[z + 1]].reshape(-1, 3)
        tris.append(bank["body_vertex"][vptr[z]:vptr[z + 1]][local])
    return np.concatenate(tris)


def raycast(points, tris, xy):
    """Front-most hit of rays along -z at each (x, y): (triangle index, barycentric weights, z)."""
    a, b, c = points[tris[:, 0]], points[tris[:, 1]], points[tris[:, 2]]
    out_tri = np.full(len(xy), -1)
    out_bary = np.zeros((len(xy), 3))
    out_z = np.full(len(xy), -np.inf)
    lo = np.minimum(np.minimum(a, b), c)[:, :2]
    hi = np.maximum(np.maximum(a, b), c)[:, :2]
    for k, (x, y) in enumerate(xy):
        cand = np.where((lo[:, 0] <= x) & (hi[:, 0] >= x) & (lo[:, 1] <= y) & (hi[:, 1] >= y))[0]
        for t in cand:
            p0, p1, p2 = a[t, :2], b[t, :2], c[t, :2]
            v0, v1, v2 = p1 - p0, p2 - p0, np.array([x, y]) - p0
            den = v0[0] * v1[1] - v1[0] * v0[1]
            if abs(den) < 1e-14:
                continue
            w1 = (v2[0] * v1[1] - v1[0] * v2[1]) / den
            w2 = (v0[0] * v2[1] - v2[0] * v0[1]) / den
            w0 = 1.0 - w1 - w2
            if min(w0, w1, w2) < -1e-6:
                continue
            z = w0 * a[t, 2] + w1 * b[t, 2] + w2 * c[t, 2]
            if z > out_z[k]:
                out_z[k], out_tri[k], out_bary[k] = z, t, (w0, w1, w2)
    return out_tri, out_bary, out_z


def main():
    bank = np.load(sys.argv[1], allow_pickle=True)
    marks = np.load(sys.argv[2], allow_pickle=True)
    points = bank["base"].astype(np.float64)
    tris = head_triangles(bank)
    path = str(marks["paths"][0])
    cam = json.load(open(os.path.splitext(path)[0] + ".json"))
    lm = marks["points"][0].astype(np.float64)
    extent, cx, cy = cam["extent"], cam["centre"][0], cam["centre"][1]
    xy = np.stack([cx + (lm[:, 0] - 0.5) * extent, cy + (0.5 - lm[:, 1]) * extent], 1)
    tri, bary, z = raycast(points, tris, xy)
    missing = int((tri < 0).sum())
    vertices = tris[np.maximum(tri, 0)]
    # MediaPipe's z: relative depth, in units of the image's width (= extent here), nearer = smaller.
    mp_z = -lm[:, 2] * extent
    ok = tri >= 0
    fit = np.polyfit(mp_z[ok], z[ok], 1)
    resid = z[ok] - np.polyval(fit, mp_z[ok])
    print(f"{len(lm)} landmarks, {missing} missed the head; MediaPipe depth ~ {fit[0]:.2f} x ours (+{fit[1]:.3f}), "
          f"residual {np.sqrt((resid ** 2).mean()) * 1000:.1f} mm rms")
    np.savez_compressed(sys.argv[3], vertices=vertices.astype(np.int32), bary=bary.astype(np.float32), valid=ok,
                        depth_scale=np.float32(fit[0]))


if __name__ == "__main__":
    sys.exit(main())
