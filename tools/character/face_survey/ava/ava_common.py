"""Ava-256 helpers: meshes, cameras, landmarks. The data lives outside the repository, in $AVA256 (default
~/datasets/ava256): data/ (fetch.py), landmarks.jsonl (dump_landmarks.tscn on data/*/*.png), the prepared files
(ava_prepare.py), targets.json (ava_targets.py)."""
import json, os, numpy as np

ROOT = os.path.expanduser(os.environ.get("AVA256", "~/datasets/ava256"))
DATA = os.path.join(ROOT, "data")
MP7 = [33, 133, 362, 263, 2, 61, 291]  # NoW's 7 landmarks as MediaPipe's


def load_ply(path):
    return np.frombuffer(open(path, "rb").read().split(b"end_header\n", 1)[1], dtype="<f4").reshape(-1, 3).astype(np.float64)


def load_landmarks(path=os.path.join(ROOT, "landmarks.jsonl")):
    out = {}
    for line in open(path):
        r = json.loads(line)
        if r["found"]:
            out[r["path"]] = np.array(r["points"]).reshape(-1, 3)
    return out


def project(meta, frame, view, verts):
    """Pixels and camera depth of head-frame vertices in a view's image (distortion left out)."""
    pose = np.array(meta["head_pose"][frame])
    cam = meta["cameras"][view]
    K, T = np.array(cam["K"]), np.array(cam["T"])
    w = (pose[:, :3] @ verts.T).T + pose[:, 3]
    c = (T[:3, :3] @ w.T).T + T[:3, 3]
    uv = (K @ c.T).T
    return uv[:, :2] / uv[:, 2:3], c[:, 2]
