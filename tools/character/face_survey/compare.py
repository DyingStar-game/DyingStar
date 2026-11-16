#!/usr/bin/env python3
"""A photo beside our render of the face fitted to it, judged fairly: iris-aligned, the render brought to the
photo's exposure, and the face's proportions measured on both.

    python compare.py <photo> <photo landmarks.npz> <render> <render landmarks.npz> <out.png>

The exposure: a studio photo's skin is often far brighter than the creator's (L 62-82 against 46-52), which makes
every colour and contrast look different by eye. The render is scaled in linear light by one gain (luminance only,
the colours kept) so that its cheeks' mean light is the photo's. Landmarks come from landmarks.py (MediaPipe venv
or any Python with numpy, Pillow and OpenCV). A dev tool like the rest of the face survey: photos and what is
measured on them stay out of the repository.

Prints, per measure, the photo's value, the render's and their gap (lengths over the distance between the irises).
"""
import sys

import cv2
import numpy as np
from PIL import Image

IRIS = (468, 473)
CHEEKS = ([116, 117, 118, 50, 205, 187, 147, 123], [345, 346, 347, 280, 425, 411, 376, 352])
# name: (landmark a, landmark b) -- a length between them, over the IOD.
LENGTHS = {
    "face width (234-454)": (234, 454), "cheekbones (116-345)": (116, 345), "jaw angles (172-397)": (172, 397),
    "eyes to chin (168-152)": (168, 152), "nose length (168-2)": (168, 2), "nose width (64-294)": (64, 294),
    "philtrum (2-0)": (2, 0), "upper lip (0-13)": (0, 13), "lower lip (14-17)": (14, 17), "chin (17-152)": (17, 152),
    "mouth width (61-291)": (61, 291), "eye width (33-133)": (33, 133), "eye opening (159-145)": (159, 145),
    "brow to eye (105-159)": (105, 159), "brow to eye (334-386)": (334, 386),
}


def linear(srgb):
    s = srgb.astype(np.float64) / 255.0
    return np.where(s <= 0.04045, s / 12.92, ((s + 0.055) / 1.055) ** 2.4)


def srgb(lin):
    s = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(np.clip(lin, 0.0, None), 1.0 / 2.4) - 0.055)
    return (np.clip(s, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def points(npz, size):
    return np.load(npz, allow_pickle=True)["points"][0][:, :2] * size


def cheek_light(rgb, p):
    mask = np.zeros(rgb.shape[:2], np.uint8)
    for c in CHEEKS:
        cv2.fillPoly(mask, [p[c].astype(np.int32)], 1)
    lin = linear(rgb)[mask.astype(bool)]
    return float((lin @ (0.2126, 0.7152, 0.0722)).mean())


def main():
    photo = np.asarray(Image.open(sys.argv[1]).convert("RGB"))
    render = np.asarray(Image.open(sys.argv[3]).convert("RGB"))
    pa = points(sys.argv[2], photo.shape[1::-1])
    pb = points(sys.argv[4], render.shape[1::-1])
    gain = cheek_light(photo, pa) / cheek_light(render, pb)
    matched = srgb(linear(render) * gain)
    # Iris-aligned: the render scaled and shifted so that its irises land on the photo's.
    iod_a = np.linalg.norm(pa[IRIS[0]] - pa[IRIS[1]])
    iod_b = np.linalg.norm(pb[IRIS[0]] - pb[IRIS[1]])
    s = iod_b / iod_a
    left = pb[list(IRIS)].mean(0) - pa[list(IRIS)].mean(0) * s
    h, w = photo.shape[:2]
    crop = Image.fromarray(matched).crop((int(left[0]), int(left[1]), int(left[0] + w * s), int(left[1] + h * s)))
    height = 640
    width = int(w * height / h)
    out = Image.new("RGB", (2 * width + 8, height), (20, 20, 20))
    out.paste(Image.fromarray(photo).resize((width, height), Image.LANCZOS), (0, 0))
    out.paste(crop.resize((width, height), Image.LANCZOS), (width + 8, 0))
    out.save(sys.argv[5])
    print(f"exposure gain on the render: x{gain:.2f}")
    print(f"{'':26s} {'photo':>7s} {'render':>7s}  gap")
    for name, (a, b) in LENGTHS.items():
        la = np.linalg.norm(pa[a] - pa[b]) / iod_a
        lb = np.linalg.norm(pb[a] - pb[b]) / iod_b
        print(f"{name:26s} {la:7.3f} {lb:7.3f}  {100.0 * (lb / la - 1.0):+4.0f} %")


if __name__ == "__main__":
    sys.exit(main())
