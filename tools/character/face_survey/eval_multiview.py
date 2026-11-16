#!/usr/bin/env python3
"""Whether side photos help the photo-to-character's face shape on real people (eval_multiview.tscn's shapes).

Each person was fitted twice from separate photos, with and without sides. A better shape is the same person's
twice and someone else's less: per pair of sets, the mean distance (mm, rigidly aligned) between one person's two
shapes, the mean distance to other people's, their ratio, and how often a person's nearest shape in the other set is
their own (identification, rank 1 and 5, out of everyone).

    python3 eval_multiview.py <prefix>[,<prefix>...] [--pairs 11:13,11-09:13-08,11-02-09:13-03-08]
"""
import argparse
import json
import sys

import numpy as np


def load(prefixes, name):
    parts = [np.fromfile(f"{p}_{name}.f32", dtype=np.float32) for p in prefixes]
    meta = [json.load(open(f"{p}.json")) for p in prefixes]
    v = meta[0]["vertices"]
    people = [e for m in meta for e in m["people"]]
    return np.concatenate(parts).reshape(-1, v, 3).astype(np.float64), people


def rigid_distance(a, b):
    """RMS distance (m) between every shape of a and every one of b, after a rigid alignment of the pair."""
    a = a - a.mean(1, keepdims=True)
    b = b - b.mean(1, keepdims=True)
    out = np.empty((len(a), len(b)))
    for i in range(len(a)):
        h = np.einsum("vk,nvl->nkl", a[i], b)  # cross-covariances with every b
        u, _, vt = np.linalg.svd(h)
        d = np.sign(np.linalg.det(u @ vt))
        fix = np.ones((len(b), 3))
        fix[:, 2] = d
        r = (u * fix[:, None, :]) @ vt  # rotation taking a[i] onto each b
        moved = np.einsum("vk,nkl->nvl", a[i], r)
        out[i] = np.sqrt(((moved - b) ** 2).sum(2).mean(1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prefixes")
    ap.add_argument("--pairs", default="11:13,11-09:13-08,11-02-09:13-03-08")
    args = ap.parse_args()
    prefixes = args.prefixes.split(",")
    for pair in args.pairs.split(","):
        first, second = pair.split(":")
        a, people = load(prefixes, first)
        b, _ = load(prefixes, second)
        ok = (np.abs(a).sum((1, 2)) > 0) & (np.abs(b).sum((1, 2)) > 0)
        sides = np.array([len(e.get(first.replace("-", ","), [])) + len(e.get(second.replace("-", ","), []))
                          for e in people])
        a, b = a[ok], b[ok]
        d = rigid_distance(a, b) * 1000.0
        same = np.diag(d)
        other = d[~np.eye(len(d), dtype=bool)].reshape(len(d), -1)
        ranks = (d < same[:, None]).sum(1)
        spread = np.sqrt(((a - a.mean(0)) ** 2).sum(2).mean()) * 1000.0
        print(f"{first:>9} vs {second:<9} {ok.sum():3d} people (photos used {sides[ok].mean():.1f}): "
              f"same person {np.mean(same):.2f} mm, others {np.mean(other):.2f} mm, ratio {np.mean(same) / np.mean(other):.3f} | "
              f"identified rank 1 {100 * np.mean(ranks == 0):.0f} %, rank 5 {100 * np.mean(ranks < 5):.0f} % | "
              f"spread between people {spread:.2f} mm")


if __name__ == "__main__":
    sys.exit(main())
