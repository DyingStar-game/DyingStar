"""Fetch from Ava-256 (CC BY-NC 4.0) only what the photo-to-character's learning needs, by HTTP range reads of
its zips: per identity two neutral frames (EXP_neutral_peak), seen by the camera most in front of the face and
the two nearest +-45 degrees at eye level, as PNG, with the frames' registered meshes (PLY, head frame, mm), head
poses and the cameras' calibration (K scaled to the images).

    python3 -I fetch.py ~/datasets/ava256/data --ids <ava-256 clone>/256_ids.csv [--count N] [--threads 8] [--profiles]
About 2.4 MB and 10 s an identity (626 MB for the 256), not the 4 TB package.
"""
import argparse, csv, io, json, math, os, subprocess, sys, tempfile, threading
from concurrent.futures import ThreadPoolExecutor
import urllib.request
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from remote_zip import open_zip

BASE = "https://fb-baas-f32eacb9-8abb-11eb-b2b8-4857dd089e15.s3.amazonaws.com/ava-256/4TB/"
SCALE = 0.25  # the 4TB package's images are a quarter of the calibration's resolution
TARGETS = {"front": 0.0, "left": -45.0, "right": 45.0}
# --profiles: the views a profile photo is taken from, 75 (a phone's "profile", NoW's) to 90 degrees.
PROFILES = {"left75": -75.0, "left90": -92.0, "right75": 75.0, "right90": 92.0}


def get(url):
    with urllib.request.urlopen(url) as r:
        return r.read()


def angles(cam, pose):
    """The camera's yaw and pitch (degrees) seen from the head: 0, 0 straight in front of the face (+z, head frame)."""
    T = np.array(cam["T"]).T
    centre = -T[:3, :3].T @ T[:3, 3]
    d = pose[:, :3].T @ (centre - pose[:, 3])
    yaw = math.degrees(math.atan2(d[0], d[2]))
    pitch = math.degrees(math.atan2(d[1], math.hypot(d[0], d[2])))
    return yaw, pitch


def add_views(dest, targets):
    """Fetch more views of an identity already fetched (the same frames), added to its meta.json."""
    meta = json.load(open(os.path.join(dest, "meta.json")))
    want = {n: a for n, a in targets.items() if n not in meta["cameras"]}
    if not want:
        return "done"
    base = BASE + meta["capture"] + "/decoder/"
    cal = json.loads(get(base + "camera_calibration.json"))["KRT"]
    pose = np.array(meta["head_pose"][meta["frames"][0]])
    taken = {c["id"] for c in meta["cameras"].values()}
    views = {}
    for name, a in want.items():
        best = None
        for cam in cal:
            yaw, pitch = angles(cam, pose)
            score = (yaw - a) ** 2 + 2.0 * pitch ** 2
            if cam["cameraId"] not in taken and (best is None or score < best[0]):
                best = (score, cam["cameraId"], yaw, pitch)
        taken.add(best[1])
        views[name] = best
    meta["cameras"].update(_images(base, cal, views, meta["frames"], dest))
    json.dump(meta, open(os.path.join(dest, "meta.json"), "w"), indent=1)
    return " ".join(f"{n} {v[2]:+.0f}/{v[3]:+.0f}" for n, v in views.items())


def _images(base, cal, views, chosen, dest):
    cams = {}
    for name, (_, cid, yaw, pitch) in views.items():
        z = open_zip(base + f"image/cam{cid}.zip")
        for f in chosen:
            with tempfile.NamedTemporaryFile(suffix=".avif") as t:
                t.write(z.read(f"cam{cid}/{f}.avif"))
                t.flush()
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", t.name,
                                os.path.join(dest, f"{f}_{name}.png")], check=True)
        cam = [c for c in cal if c["cameraId"] == cid][0]
        k = np.array(cam["K"]).T
        k[:2] *= SCALE
        cams[name] = {"id": cid, "yaw": yaw, "pitch": pitch, "K": k.tolist(), "T": np.array(cam["T"]).T.tolist(),
                      "distortion": cam["distortion"]}
    return cams


def fetch(row, out, profiles=False):
    folder = f"{row['mcd']}--{row['mct']}--{row['sid']}"
    dest = os.path.join(out, row["sid"])
    if os.path.exists(os.path.join(dest, "meta.json")):
        return row["sid"], add_views(dest, PROFILES) if profiles else "done"
    base = BASE + folder + "/decoder/"
    frames = [l.split(",") for l in get(base + "frame_list.csv").decode().splitlines()[1:]]
    neutral = [f for s, f in frames if s == "EXP_neutral_peak"] or [f for s, f in frames if s == "EXP_eye_neutral"]
    if not neutral:
        return row["sid"], "no neutral frames"
    chosen = sorted({neutral[len(neutral) // 3], neutral[(2 * len(neutral)) // 3]})
    chosen = [f.zfill(6) for f in chosen]
    cal = json.loads(get(base + "camera_calibration.json"))["KRT"]
    poses_zip = open_zip(base + "head_pose/head_pose.zip")
    poses = {f: np.loadtxt(io.StringIO(poses_zip.read(f + ".txt").decode())) for f in chosen}
    pose = poses[chosen[0]]
    views = {}
    for cam in cal:
        yaw, pitch = angles(cam, pose)
        for name, want in TARGETS.items():
            score = (yaw - want) ** 2 + 2.0 * pitch ** 2
            if name not in views or score < views[name][0]:
                views[name] = (score, cam["cameraId"], yaw, pitch)
    os.makedirs(dest, exist_ok=True)
    mesh_zip = open_zip(base + "kinematic_tracking/registration_vertices.zip")
    for f in chosen:
        open(os.path.join(dest, f + ".ply"), "wb").write(mesh_zip.read(f + ".ply"))
    cams = _images(base, cal, views, chosen, dest)
    meta = {"identity": row["sid"], "capture": folder, "frames": chosen, "head_pose": {f: poses[f].tolist() for f in chosen},
            "cameras": cams, "licence": "Ava-256, Meta Platforms, CC BY-NC 4.0 (github.com/facebookresearch/ava-256)"}
    json.dump(meta, open(os.path.join(dest, "meta.json"), "w"), indent=1)
    return row["sid"], " ".join(f"{n} {v[2]:+.0f}/{v[3]:+.0f}" for n, v in views.items())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--count", type=int, default=256)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--profiles", action="store_true", help="also fetch the profile views (PROFILES), adding them to identities already fetched")
    ap.add_argument("--ids", required=True, help="256_ids.csv of github.com/facebookresearch/ava-256")
    args = ap.parse_args()
    rows = list(csv.DictReader(open(args.ids)))[: args.count]
    lock = threading.Lock()

    def run(row):
        try:
            sid, note = fetch(row, args.out, args.profiles)
        except Exception as e:  # one identity's failure must not stop the rest
            sid, note = row["sid"], f"FAILED {e!r}"
        with lock:
            print(sid, note, flush=True)

    with ThreadPoolExecutor(args.threads) as pool:
        list(pool.map(run, rows))


if __name__ == "__main__":
    main()
