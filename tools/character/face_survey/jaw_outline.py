#!/usr/bin/env python3
"""The jaw's true outline on photos, for photo_fit.py --outline: MediaPipe's face landmarks run a smooth oval
inside it (on a square jaw or a broad chin they cut the corners), so the fit narrowed those. The outline is
the lower edge of the multiclass selfie segmenter's face-skin class, from the ear lobes down.

    python jaw_outline.py <segmenter.tflite> <landmarks.npz> <out.npz>

Writes per face `outline` (an object array of (N, 2) pixel points in the photo). A dev tool, like the rest of
the face survey: photos and what is measured on them stay out of the repository. Run with the MediaPipe venv.
"""
import sys

import cv2
import numpy as np

EAR_L, EAR_R = 132, 361  # the jaw's back, about the ear lobes' height
FACE_SKIN = 3


def outline(segmenter, image, points):
    import mediapipe as mp
    h, w = image.shape[:2]
    p = points[:, :2] * (w, h)
    mask = segmenter.segment(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(image, cv2.COLOR_BGR2RGB)))
    mask = mask.category_mask.numpy_view()
    face = (mask[:, :, 0] if mask.ndim == 3 else mask) == FACE_SKIN
    face = cv2.morphologyEx(face.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8)).astype(bool)
    top = int(min(p[EAR_L, 1], p[EAR_R, 1]))
    out = []
    for y in range(top, h):  # the sides, row by row
        xs = np.nonzero(face[y])[0]
        if len(xs) > 1:
            out += [(xs[0], y), (xs[-1], y)]
    for x in range(w):  # the chin's underside, column by column
        ys = np.nonzero(face[top:, x])[0]
        if len(ys):
            out.append((x, top + ys[-1]))
    return np.unique(np.array(out, dtype=np.float32), axis=0)


def main():
    from mediapipe.tasks import python as mpt
    from mediapipe.tasks.python import vision
    seg = vision.ImageSegmenter.create_from_options(vision.ImageSegmenterOptions(
        base_options=mpt.BaseOptions(model_asset_path=sys.argv[1]), output_category_mask=True))
    z = np.load(sys.argv[2], allow_pickle=True)
    result = np.empty(len(z["paths"]), dtype=object)
    for k, path in enumerate(z["paths"]):
        result[k] = outline(seg, cv2.imread(str(path)), z["points"][k])
        print(f"{path}: {len(result[k])} outline points")
    np.savez(sys.argv[3], outline=result, paths=z["paths"])


if __name__ == "__main__":
    main()
