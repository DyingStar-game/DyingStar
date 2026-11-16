#!/usr/bin/env python3
"""Carry FLAME 2023 Open's identity directions onto the Vitruvian head: new shape keys of the character bank.

    python3 transfer_flame.py <flame.pkl> <registration.npz> <human_bank.npz> <project root> [--count 50]

registration.npz comes from register_flame.py fit (FLAME laid on our neutral head). Each of our head's vertices is
tied to the nearest vertices of that laid FLAME (the eyes to their eyeball), and FLAME's identity direction k,
turned and scaled as the registration placed FLAME, is carried over by inverse-distance weights. The effect fades
to nothing towards the neck's join with the torso, so that no new key opens the seam between the head mesh and the
body mesh (HumanBuilder: the head and the body meet on vertices that must not move). Where hair grows (the
groom's hairline, tools/character/hair_groom), each direction is replaced by its closest affine change, FLAME's
own coming back over SCALP_BLEND under the hairline (the top of the forehead; the brows keep it whole): a head of hair is one rigid mesh carried by an affine
fit of its roots (HairStrands.fit), so any mix of these keys must change the scalp affinely, or the hair floats
or sinks. The skull's proportions stay; only its local bumps are lost.

Writes into human_bank.npz targets FLAME_Identity_00.. (one standard deviation of real faces each; a run replaces
the previous run's), appends their sliders to the catalogue (bank and runtime human_catalogue.json, tab "flame",
append-only), their labels to tools/localization/localisation.csv, and the credit to human_bank.txt.

FLAME 2023 Open: Max Planck Institute for Intelligent Systems, CC BY 4.0. Li, Bolkart, Black, Li, Romero: Learning a
model of facial shape and expression from 4D scans, ACM ToG (SIGGRAPH Asia) 2017.
"""
import argparse
import csv
import json
import os
import sys

import numpy as np
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "hair_groom"))
from flame_model import Flame  # noqa: E402
from groom import Head, unit  # noqa: E402

PREFIX = "FLAME_Identity_"
TAB = "flame"
DENSE_FRACTION = 0.6
NEIGHBOURS = 4
NECK_FADE = 0.07  # m above the head/body join over which a key fades in
SCALP_BLEND = 0.07  # under the hairline (sine of the elevation from the skull's centre; the brows are 0.08-0.23 under)
ROOT_REACH = 0.015  # m around the skin vertices a hair root is tied to, also affine (the temples' roots dip under the line)
EYE_ZONES = ("Iris", "Pupil", "Sclera_Cornea")
BODY_ZONES = ("Torso", "Arms", "Legs")
CATALOGUE_REL = "assets/_universe/characters/human/human_catalogue.json"
LABELS_REL = "tools/localization/localisation.csv"
CREDIT_REL = "assets/_universe/characters/human/human_bank.txt"
CREDITS = [
    "Blender Artists - Hopefullyidont1 (Vitruvian Project) - https://blenderartists.org/t/open-source-customizable-digital-human-vitruvian-project/1457388 - CC0",
    "Max Planck Institute for Intelligent Systems - FLAME 2023 Open (identity directions carried onto the Vitruvian head) - https://flame.is.tue.mpg.de - CC BY 4.0",
]


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def read_targets(bank):
    """Every target of the bank as (name, vertex indices, int16 deltas (k, 3), scale)."""
    out = []
    n = len(bank["base"])
    for t, name in enumerate(bank["target_names"]):
        start, count = int(bank["target_delta_start"][t]), int(bank["target_count"][t])
        q = bank["delta"][start:start + 3 * count].reshape(-1, 3)
        if bank["target_dense"][t]:
            idx = np.arange(n)
        else:
            s = int(bank["target_sparse_start"][t])
            idx = bank["sparse_index"][s:s + count].astype(np.int64)
        out.append((str(name), idx, q, float(bank["target_scale"][t])))
    return out


def write_targets(bank, targets):
    n = len(bank["base"])
    names, scales, starts, counts, dense_flags, sparse_idx, deltas = [], [], [], [], [], [], []
    cursor = 0
    for name, idx, q, scale in targets:
        dense = len(idx) > DENSE_FRACTION * n
        names.append(name)
        scales.append(scale)
        dense_flags.append(dense)
        starts.append(cursor)
        if dense:
            block = np.zeros((n, 3), dtype=np.int16)
            block[idx] = q
            counts.append(n)
            deltas.append(block.reshape(-1))
            cursor += n * 3
        else:
            counts.append(len(idx))
            sparse_idx.append(idx.astype(np.uint16))
            deltas.append(q.reshape(-1).astype(np.int16))
            cursor += len(idx) * 3
    sparse_start, run = [], 0
    for dense, count in zip(dense_flags, counts):
        sparse_start.append(-1 if dense else run)
        run += 0 if dense else count
    bank.update({
        "target_names": np.array(names), "target_scale": np.array(scales, dtype=np.float32),
        "target_delta_start": np.array(starts, dtype=np.int32), "target_count": np.array(counts, dtype=np.int32),
        "target_dense": np.array(dense_flags, dtype=np.uint8), "target_sparse_start": np.array(sparse_start, dtype=np.int32),
        "sparse_index": np.concatenate(sparse_idx), "delta": np.concatenate(deltas).astype(np.int16),
    })


def encode(delta):
    """(n, 3) metres -> sparse (vertex indices, int16 deltas, scale)."""
    moved = np.where(np.abs(delta).max(1) > 1e-7)[0]
    d = delta[moved]
    peak = float(np.abs(d).max()) if len(d) else 0.0
    scale = peak / 32767.0 if peak > 0 else 1.0
    return moved, np.round(d / scale).astype(np.int16), scale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("flame")
    ap.add_argument("registration")
    ap.add_argument("bank")
    ap.add_argument("root")
    ap.add_argument("--count", type=int, default=50)
    args = ap.parse_args()
    flame = Flame(args.flame)
    reg = np.load(args.registration)
    placed, rot, scale = reg["placed"], reg["rotation"], float(reg["scale"])
    bank = dict(np.load(args.bank, allow_pickle=True))
    base = bank["base"].astype(np.float64)
    zones = [str(z) for z in bank["zone_names"]]
    vptr = bank["zone_vertex_ptr"]

    def zone_ids(name):
        z = zones.index(name)
        return np.unique(bank["body_vertex"][vptr[z]:vptr[z + 1]])

    body = np.unique(np.concatenate([zone_ids(z) for z in BODY_ZONES if z in zones]))
    head_zones = [z for z in zones if z not in BODY_ZONES]
    head = np.unique(np.concatenate([zone_ids(z) for z in head_zones]))
    border = np.intersect1d(head, body)  # where the head mesh meets the body's
    join = float(base[border, 1].max())
    fade = smoothstep(join, join + NECK_FADE, base[:, 1])
    fade[border] = 0.0
    # Each head vertex: its FLAME neighbours (the eyes on their eyeball, the rest on the head).
    groups = {0: np.setdiff1d(head, np.concatenate([zone_ids(z) for z in EYE_ZONES]))}
    for z in EYE_ZONES:
        ids = zone_ids(z)
        for side, sign in ((1, 1.0), (2, -1.0)):
            mine = ids[np.sign(base[ids, 0]) == sign]
            groups[side] = np.union1d(groups.get(side, np.zeros(0, dtype=np.int64)), mine)
    links = []  # (our vertices, FLAME neighbour indices (n, k), weights (n, k))
    for part, ours in groups.items():
        flame_ids = np.where(flame.part == part)[0]
        dist, nb = cKDTree(placed[flame_ids]).query(base[ours], k=NEIGHBOURS)
        w = 1.0 / np.maximum(dist, 1e-5) ** 2
        w /= w.sum(1, keepdims=True)
        links.append((ours, flame_ids[nb], w))
        print(f"part {part}: {len(ours)} of our vertices, nearest FLAME vertex {np.median(dist[:, 0]) * 1000:.2f} mm median, "
              f"{np.percentile(dist[:, 0], 99) * 1000:.1f} mm p99")
    # Where the scalp's change must be affine: 1 from the hairline up (every root of a head of hair), 0 SCALP_BLEND under.
    groom_head = Head(bank)
    ids = groom_head.face_ids
    u = unit(base[ids] - groom_head.centre)
    above = (u[:, 1] - groom_head.hairline(np.arctan2(u[:, 0], u[:, 2]))) / SCALP_BLEND
    affine = np.zeros(len(base))
    affine[ids] = smoothstep(-1.0, 0.0, above)
    meta = json.loads(str(bank["asset_meta_json"]))
    tied = np.unique(np.concatenate([bank[f"asset{i}_refs"] for i, m in enumerate(meta) if m.get("style") == "strands"]))
    near_root, _i = cKDTree(base[tied]).query(base[ids])
    affine[ids] = np.maximum(affine[ids], smoothstep(ROOT_REACH, 0.0, near_root))
    scalp = np.where(affine > 0.999)[0]
    blended = np.where(affine > 0.0)[0]
    lift = np.concatenate([base, np.ones((len(base), 1))], 1)
    print(f"scalp: {len(scalp)} vertices kept affine, {len(blended) - len(scalp)} blended")
    targets = [t for t in read_targets(bank) if not t[0].startswith(PREFIX)]
    new_keys = []
    for k in range(args.count):
        direction = (flame.identity[:, :, k] @ rot.T) * scale  # FLAME's direction k, as FLAME was laid on our head
        delta = np.zeros_like(base)
        for ours, nb, w in links:
            delta[ours] = (direction[nb] * w[..., None]).sum(1)
        delta *= fade[:, None]
        fit, *_ = np.linalg.lstsq(lift[scalp], delta[scalp], rcond=None)  # (4, 3): the closest affine change
        if k < 3:
            residual = np.linalg.norm(delta[scalp] - lift[scalp] @ fit, axis=1)
            print(f"{PREFIX}{k:02d}: scalp off affine by {np.percentile(residual, 99) * 1000:.2f} mm (p99), now 0")
        a = affine[blended, None]
        delta[blended] = (1.0 - a) * delta[blended] + a * (lift[blended] @ fit)
        key = f"{PREFIX}{k:02d}"
        targets.append((key, *encode(delta)))
        new_keys.append(key)
        if k < 3 or k == args.count - 1:
            rms = np.sqrt((delta[head] ** 2).sum(1).mean()) * 1000
            print(f"{key}: {rms:.2f} mm rms over the head, {np.abs(delta).max() * 1000:.1f} mm at most")
    write_targets(bank, targets)
    # The catalogue, append-only: a key already there keeps its position.
    catalogue = json.loads(str(bank["catalogue_json"]))
    known = {c["key"] for c in catalogue}
    for key in new_keys:
        if key not in known:
            catalogue.append({"key": key, "tab": TAB, "label": "%%CHAR_MOD_" + key.upper(), "unipolar": False, "signed": True,
                              "negative": [], "positive": [key]})
    bank["catalogue_json"] = np.array(json.dumps(catalogue))
    np.savez_compressed(args.bank, **bank)
    runtime_path = os.path.join(args.root, CATALOGUE_REL)
    runtime = json.load(open(runtime_path))
    known = {m["key"] for m in runtime["modifiers"]}
    for key in new_keys:
        if key not in known:
            runtime["modifiers"].append({"key": key, "tab": TAB, "label": "%%CHAR_MOD_" + key.upper(), "unipolar": False})
    json.dump(runtime, open(runtime_path, "w"), indent=1)
    labels_path = os.path.join(args.root, LABELS_REL)
    text = open(labels_path, encoding="utf-8").read()
    with open(labels_path, "a", encoding="utf-8", newline="") as f:
        if not text.endswith("\n"):
            f.write("\n")
        writer = csv.writer(f, lineterminator="\n")
        for k, key in enumerate(new_keys):
            label = "%%CHAR_MOD_" + key.upper()
            if label + "," not in text:
                writer.writerow([label, f"Real face shape {k + 1}", f"Forme de visage réelle {k + 1}", ""])
    credit_path = os.path.join(args.root, CREDIT_REL)
    lines = [l.rstrip("\n") for l in open(credit_path)]
    for line in CREDITS:
        if line not in lines:
            lines.append(line)
    open(credit_path, "w").write("\n".join(lines) + "\n")
    print(f"{len(new_keys)} FLAME identity keys in {args.bank}; catalogue {len(runtime['modifiers'])} sliders")


if __name__ == "__main__":
    sys.exit(main())
