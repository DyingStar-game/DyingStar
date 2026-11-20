#!/usr/bin/env python3
"""Which FFHQ adults are of European origin, as FairFace's classifier reads them -- to learn European faces' types
(face_types.py). Nothing here is shipped: the classifier is a tool, its per-photo guesses stay in ~/datasets.

FairFace (Kärkkäinen & Joo 2021, github.com/joojs/fairface, CC BY 4.0): a ResNet-34 trained on a race-balanced set,
18 outputs -- 7 groups (White, Black, Latino_Hispanic, East Asian, Southeast Asian, Indian, Middle Eastern), 2 sexes,
9 age bands. Its weights (res34_fair_align_multi_7_20190809.pt, sha256 37f2e74c...) in ~/datasets/fairface/: the
project's Google Drive folder is gone, a copy is at huggingface.co/wmpscc/StyleGene.

It was trained on dlib's aligned face chips (300 px, 0.25 padding); FFHQ's photos are aligned on the eyes already, so
the chip is cut from MediaPipe's landmarks (landmarks.py's npz): their box, 25 % more a side, square.

    ~/datasets/ffhq/.torch/bin/python ethnicity.py ~/datasets/ffhq/survey/adults_lm.npz \\
        ~/datasets/ffhq/survey/ethnicity.npz [--preview DIR]
"""
import argparse
import os
import sys

import numpy as np
import torch
import torchvision
from PIL import Image

WEIGHTS = os.path.expanduser("~/datasets/fairface/res34_fair_align_multi_7_20190809.pt")
GROUPS = ["White", "Black", "Latino_Hispanic", "East Asian", "Southeast Asian", "Indian", "Middle Eastern"]
PADDING = 0.25
SIZE = 224
MEAN = torch.tensor([0.485, 0.456, 0.406]).view(3, 1, 1)
STD = torch.tensor([0.229, 0.224, 0.225]).view(3, 1, 1)


def chip(path, points):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    xs, ys = points[:, 0] * w, points[:, 1] * h
    cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
    half = max(xs.max() - xs.min(), ys.max() - ys.min()) * (0.5 + PADDING)
    return img.crop((int(cx - half), int(cy - half), int(cx + half), int(cy + half))).resize((SIZE, SIZE), Image.BILINEAR)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("landmarks")
    ap.add_argument("out")
    ap.add_argument("--preview", help="write the first 40 chips there, to check the framing")
    ap.add_argument("--batch", type=int, default=64)
    a = ap.parse_args()
    lm = np.load(a.landmarks)
    paths, points = lm["paths"], lm["points"]
    net = torchvision.models.resnet34()
    net.fc = torch.nn.Linear(net.fc.in_features, 18)
    net.load_state_dict(torch.load(WEIGHTS, map_location="cpu", weights_only=True))
    device = "cuda" if torch.cuda.is_available() else "cpu"
    net = net.to(device).eval()
    if a.preview:
        os.makedirs(a.preview, exist_ok=True)
    groups = np.zeros((len(paths), 7), np.float32)
    sexes = np.zeros((len(paths), 2), np.float32)
    ages = np.zeros((len(paths), 9), np.float32)
    with torch.no_grad():
        for start in range(0, len(paths), a.batch):
            batch = []
            for i in range(start, min(start + a.batch, len(paths))):
                c = chip(paths[i], points[i])
                if a.preview and i < 40:
                    c.save(os.path.join(a.preview, f"{i:02d}.jpg"))
                t = torch.from_numpy(np.asarray(c, np.float32) / 255.0).permute(2, 0, 1)
                batch.append((t - MEAN) / STD)
            out = net(torch.stack(batch).to(device)).float().cpu()
            end = start + len(batch)
            groups[start:end] = torch.softmax(out[:, :7], 1).numpy()
            sexes[start:end] = torch.softmax(out[:, 7:9], 1).numpy()
            ages[start:end] = torch.softmax(out[:, 9:18], 1).numpy()
            if (start // a.batch) % 50 == 0:
                print(f"ethnicity: {end} / {len(paths)}", flush=True)
    np.savez(a.out, paths=paths, groups=groups, group_names=np.array(GROUPS), sexes=sexes, ages=ages)
    best = groups.argmax(1)
    for g, name in enumerate(GROUPS):
        print(f"  {name:16s} {int((best == g).sum()):6d}  (p >= 0.7: {int((groups[:, g] >= 0.7).sum())})")


if __name__ == "__main__":
    sys.exit(main())
