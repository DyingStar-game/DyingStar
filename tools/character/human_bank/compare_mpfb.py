"""Numpy side of the parity check: rebuild verify_against_mpfb.py's humans and compare.

Vertices and the game_engine rig's bone heads / tails, MPFB (Blender frame) vs human_model.py
(MakeHuman frame -> Blender: (x, y, z) * 0.1 -> (x, -z, y)). Fails (exit 1) beyond the tolerances.

usage: python3 compare_mpfb.py parity.npz [--fixtures out.json]
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from human_model import HumanModel  # noqa: E402

VERT_TOL_MM = 0.05
JOINT_TOL_MM = 0.5

data = np.load(sys.argv[1], allow_pickle=False)
looks = json.loads(str(data["looks"]))
bones = [str(b) for b in data["bone_names"]]
model = HumanModel()


def to_blender(p: np.ndarray) -> np.ndarray:
    p = p * 0.1
    return np.stack([p[..., 0], -p[..., 2], p[..., 1]], axis=-1)


worst_v, worst_j, fixtures = 0.0, 0.0, []
for i, look in enumerate(looks):
    stack = model.stack(look["macros"], look["race"], [(n, w) for n, w in look["modifiers"]])
    verts = model.build(stack)
    dv = np.linalg.norm(to_blender(verts) - data["verts"][i], axis=1).max() * 1000
    joints = model.joints(verts)
    heads = to_blender(np.array([joints[b][0] for b in bones]))
    tails = to_blender(np.array([joints[b][1] for b in bones]))
    dj = max(np.linalg.norm(heads - data["heads"][i], axis=1).max(), np.linalg.norm(tails - data["tails"][i], axis=1).max()) * 1000
    worst_v, worst_j = max(worst_v, dv), max(worst_j, dj)
    print(f"look {i:2d}: {len(stack):3d} targets  verts max {dv:.4f} mm  joints max {dj:.4f} mm")
    fixtures.append({"look": look, "stack": sorted([[k, round(w, 6)] for k, w in stack])})

print(f"WORST verts {worst_v:.4f} mm (tol {VERT_TOL_MM}), joints {worst_j:.4f} mm (tol {JOINT_TOL_MM})")
if "--fixtures" in sys.argv:
    with open(sys.argv[sys.argv.index("--fixtures") + 1], "w") as f:
        json.dump(fixtures, f, indent=1)
sys.exit(0 if worst_v <= VERT_TOL_MM and worst_j <= JOINT_TOL_MM else 1)
