"""Check the numpy HumanModel against a body MPFB built in Blender (build_face_reference.py's .npz).

The reference holds the man_ddurieux human's body proxy, eyebrows, teeth and tongue as MPFB fitted
them (Blender frame: Z up, metres, feet on the ground). Building the same .mhm here and fitting the same
assets must give the same points up to the frame change: (x, y, z)_MH * 0.1 -> (x, -z, y)_Blender, plus
a vertical shift. Prints the residual per asset.

usage: python3 check_reference.py reference.npz man_ddurieux.mhm
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_formats  # noqa: E402
from human_model import DEFAULT_USER, HumanModel  # noqa: E402

ref = np.load(sys.argv[1], allow_pickle=False)
mhm = mh_formats.parse_mhm(sys.argv[2])
model = HumanModel()
macros = {"gender": 0.5, "age": 0.5, "muscle": 0.5, "weight": 0.5, "height": 0.5, "proportions": 0.5,
          "cupsize": 0.5, "firmness": 0.5}
macros.update(mhm["macros"])
stack = model.stack(macros, mhm["race"], mhm["modifiers"])
missing = [k for k, _ in stack if not model.has_target(k)]
print(f"{len(stack)} targets in the stack, {len(missing)} missing: {missing[:5]}")
stack = [(k, w) for k, w in stack if model.has_target(k)]
verts = model.build(stack)

assets = {
    "body": f"{DEFAULT_USER}/proxymeshes/male_muscle_13290/male_muscle_13290.proxy",
    "eyebrows": f"{DEFAULT_USER}/eyebrows/eyebrow004/eyebrow004.mhclo",
    "teeth": f"{DEFAULT_USER}/teeth/teeth_base/teeth_base.mhclo",
    "tongue": f"{DEFAULT_USER}/tongue/tongue01/tongue01.mhclo",
}
shift = None
for key, path in assets.items():
    mine = HumanModel.fit(mh_formats.load_mhclo(path), verts) * 0.1
    mine = np.column_stack([mine[:, 0], -mine[:, 2], mine[:, 1]])  # MakeHuman -> Blender frame
    theirs = ref[f"{key}_rest"]
    n = min(len(mine), len(theirs))
    if shift is None:
        shift = (theirs[:n] - mine[:n]).mean(axis=0)
    err = np.linalg.norm(mine[:n] + shift - theirs[:n], axis=1) * 1000
    print(f"{key:9s} {n:6d} verts  rms {np.sqrt((err ** 2).mean()):.4f} mm  max {err.max():.4f} mm")
print("frame shift (Blender, m):", np.round(shift, 5), " ground (MH dm):", round(model.ground(verts), 4))
