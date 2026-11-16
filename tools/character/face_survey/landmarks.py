#!/usr/bin/env python3
"""MediaPipe Face Landmarker over a set of images -> one .npz of landmarks.

    python landmarks.py <face_landmarker.task> <out.npz> <image or dir or list.txt>... [--workers 6]

Per image: the 478 landmarks (x, y in 0..1 of the image, z in the same unit as x, smaller = nearer the camera),
the 52 expression scores (ARKit names) and the 4x4 facial transformation matrix (MediaPipe's canonical face
to the camera, in cm). Images where no face is found are listed in `missed`.

Needs Python 3.9-3.12 with mediapipe, opencv-python-headless, numpy (a venv of its own).
"""
import argparse
import glob
import os
import sys
from concurrent.futures import ProcessPoolExecutor

import numpy as np

_landmarker = None


def _init(model):
    global _landmarker
    import mediapipe as mp
    from mediapipe.tasks.python import BaseOptions, vision
    options = vision.FaceLandmarkerOptions(base_options=BaseOptions(model_asset_path=model), num_faces=1,
                                           output_face_blendshapes=True, output_facial_transformation_matrixes=True)
    _landmarker = vision.FaceLandmarker.create_from_options(options)
    globals()["mp"] = mp


def _one(path):
    image = mp.Image.create_from_file(path)
    result = _landmarker.detect(image)
    if not result.face_landmarks:
        return path, None
    points = np.array([[p.x, p.y, p.z] for p in result.face_landmarks[0]], dtype=np.float32)
    scores = np.array([c.score for c in result.face_blendshapes[0]], dtype=np.float32)
    names = [c.category_name for c in result.face_blendshapes[0]]
    matrix = np.array(result.facial_transformation_matrixes[0], dtype=np.float32)
    return path, (points, scores, matrix, names)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("out")
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()
    paths = []
    for item in args.inputs:
        if os.path.isdir(item):
            paths += sorted(glob.glob(os.path.join(item, "**", "*.png"), recursive=True))
        elif item.endswith(".txt"):
            paths += [l.strip() for l in open(item) if l.strip()]
        else:
            paths.append(item)
    names, points, scores, matrices, kept, missed = None, [], [], [], [], []
    with ProcessPoolExecutor(args.workers, initializer=_init, initargs=(args.model,)) as pool:
        for k, (path, found) in enumerate(pool.map(_one, paths, chunksize=16)):
            if found is None:
                missed.append(path)
            else:
                points.append(found[0])
                scores.append(found[1])
                matrices.append(found[2])
                names = found[3]
                kept.append(path)
            if (k + 1) % 2000 == 0:
                print(f"{k + 1}/{len(paths)}", flush=True)
    np.savez_compressed(args.out, paths=np.array(kept), points=np.array(points), scores=np.array(scores),
                        matrices=np.array(matrices), blendshape_names=np.array(names or []), missed=np.array(missed))
    print(f"{len(kept)} faces, {len(missed)} missed -> {args.out}")


if __name__ == "__main__":
    sys.exit(main())
