"""Two things ava_targets.py needs about Ava-256's mesh topology (the same for every identity), worked out once:

  ava_landmarks7.json: NoW's 7 alignment landmarks (MediaPipe's 33, 133, 362, 263, 2, 61, 291) as Ava vertices --
      every front photo's MediaPipe landmarks cast onto its frame's mesh (the visible vertex nearest each landmark's
      pixel), then per landmark the vertex nearest the votes' weighted centre on one mean mesh.
  ava_outer.npy: the vertices of the mesh's outer surface -- those in a triangle and visible (z-buffer) from the
      front or +-25/45 degrees on that mean mesh: the topology also holds the mouth's inside and loose vertices
      (eyes, teeth) a scan never sees, which an oracle fit must not chase (2.7 -> 1.0 mm on one frame).

    python3 -I ava_prepare.py --topology <ava-256 clone>/assets/face_topology.obj
The mean mesh is the first identity's kinematic_tracking/registration_vertices_mean.npy (fetched here).
"""
import argparse, collections, glob, json, os, sys, urllib.request
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ava_common import DATA, MP7, ROOT, load_landmarks, load_ply, project

BASE = "https://fb-baas-f32eacb9-8abb-11eb-b2b8-4857dd089e15.s3.amazonaws.com/ava-256/4TB/"


def mean_mesh():
    path = os.path.join(ROOT, "registration_vertices_mean.npy")
    if not os.path.exists(path):
        meta = json.load(open(sorted(glob.glob(DATA + "/*/meta.json"))[0]))
        urllib.request.urlretrieve(BASE + meta["capture"] + "/decoder/kinematic_tracking/registration_vertices_mean.npy", path)
    return np.load(path).astype(np.float64)


def landmarks7(mean):
    lm = load_landmarks()
    votes = [collections.Counter() for _ in MP7]
    for meta_path in sorted(glob.glob(DATA + "/*/meta.json")):
        meta = json.load(open(meta_path))
        d = os.path.dirname(meta_path)
        for f in meta["frames"]:
            img = f"{d}/{f}_front.png"
            if img not in lm:
                continue
            v = load_ply(f"{d}/{f}.ply")
            uv, depth = project(meta, f, "front", v)
            front = v[:, 2] > 0
            for k, i in enumerate(MP7):
                dd = np.linalg.norm(uv - lm[img][i, :2], axis=1)
                near = np.where(front & (dd < 3.0))[0]
                if len(near):
                    votes[k][int(near[np.argmin(depth[near])])] += 1
    out = []
    for v in votes:
        ids = np.array(list(v.keys()))
        w = np.array(list(v.values()), float)
        centre = (mean[ids] * w[:, None]).sum(0) / w.sum()
        out.append(int(np.argmin(np.linalg.norm(mean - centre, axis=1))))
    return out


def outer_surface(mean, topology, resolution=1400):
    faces = []
    for line in open(topology):
        if line.startswith("f "):
            f = [int(x.split("/")[0]) - 1 for x in line.split()[1:]]
            faces += [[f[0], f[k], f[k + 1]] for k in range(1, len(f) - 1)]
    faces = np.array(faces)
    in_face = np.zeros(len(mean), bool)
    in_face[faces.ravel()] = True
    visible = np.zeros(len(mean), bool)
    for yaw in (0, -45, 45, -25, 25):
        a = np.radians(yaw)
        rot = np.array([[np.cos(a), 0, np.sin(a)], [0, 1, 0], [-np.sin(a), 0, np.cos(a)]])
        p = mean @ rot.T
        lo = p[:, :2].min(0)
        uv = (p[:, :2] - lo) * (resolution - 1) / (p[:, :2].max(0) - lo).max()
        depth = -p[:, 2]
        zbuf = np.full((resolution, resolution), np.inf)
        for tri in faces:
            q, z = uv[tri], depth[tri]
            x0, y0 = np.floor(q.min(0)).astype(int)
            x1, y1 = np.ceil(q.max(0)).astype(int)
            xs, ys = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
            P = np.stack([xs.ravel() + 0.0, ys.ravel() + 0.0], 1)
            v0, v1 = q[1] - q[0], q[2] - q[0]
            den = v0[0] * v1[1] - v1[0] * v0[1]
            if abs(den) < 1e-9:
                continue
            w = P - q[0]
            b1 = (w[:, 0] * v1[1] - v1[0] * w[:, 1]) / den
            b2 = (v0[0] * w[:, 1] - w[:, 0] * v0[1]) / den
            ins = (b1 >= -0.01) & (b2 >= -0.01) & (b1 + b2 <= 1.01)
            if not ins.any():
                continue
            zz = z[0] + b1[ins] * (z[1] - z[0]) + b2[ins] * (z[2] - z[0])
            px = np.clip(P[ins].astype(int), 0, resolution - 1)
            np.minimum.at(zbuf, (px[:, 1], px[:, 0]), zz)
        pix = np.clip(np.round(uv).astype(int), 0, resolution - 1)
        visible |= in_face & (depth <= zbuf[pix[:, 1], pix[:, 0]] + 1.5)
    return np.where(visible)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", required=True)
    args = ap.parse_args()
    mean = mean_mesh()
    idx = landmarks7(mean)
    json.dump({"mp7_vertices": idx}, open(os.path.join(ROOT, "ava_landmarks7.json"), "w"))
    outer = outer_surface(mean, args.topology)
    np.save(os.path.join(ROOT, "ava_outer.npy"), outer)
    p = mean[idx]
    print(f"7 landmarks {idx} (outer eye corners {np.linalg.norm(p[0] - p[3]):.0f} mm apart); outer surface {len(outer)} vertices")


if __name__ == "__main__":
    main()
