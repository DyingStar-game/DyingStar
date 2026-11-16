"""Blender + MPFB side of the parity check: build random humans with MPFB and dump them.

For each seeded random appearance (macros, race mix, a few modifier targets) MPFB builds the basemesh
and fits the game_engine rig; this writes the mixed vertices (Blender frame) and the bone heads/tails.
compare_mpfb.py then builds the same appearances with human_model.py and reports the differences.

usage: BLENDER_USER_RESOURCES=~/.config/blender/5.1 blender -b --python verify_against_mpfb.py -- out.npz [count]
"""
import json
import os
import random
import sys

import bpy
import numpy as np
from bl_ext.blender_org.mpfb.services import HumanService, TargetService

args = sys.argv[sys.argv.index("--") + 1:]
OUT = args[0]
COUNT = int(args[1]) if len(args) > 1 else 20
MODIFIER_POOL = ["nose-trans-up", "nose-scale-horiz-incr", "mouth-scale-horiz-decr", "head-fat-incr", "head-oval",
                 "chin-prominent-incr", "l-ear-scale-incr", "torso-scale-vert-incr", "upperlegs-height-incr",
                 "neck-scale-depth-decr", "r-eye-height1-incr", "forehead-trans-backward"]


def appearance(seed: int) -> dict:
    rnd = random.Random(seed)
    race = [rnd.random() for _ in range(3)]
    total = sum(race)
    return {
        "macros": {"gender": rnd.random(), "age": rnd.uniform(0.19, 1.0), "muscle": rnd.random(),
                   "weight": rnd.random(), "height": rnd.random(), "proportions": rnd.random(),
                   "cupsize": rnd.random(), "firmness": rnd.random()},
        "race": {"african": race[0] / total, "asian": race[1] / total, "caucasian": race[2] / total},
        "modifiers": [(name, round(rnd.uniform(0.1, 1.0), 3)) for name in rnd.sample(MODIFIER_POOL, 4)],
    }


looks, verts, heads, tails = [], [], [], []
bone_names = None
for i in range(COUNT):
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    look = appearance(1000 + i)
    macro = TargetService.get_default_macro_info_dict()
    macro.update({k: v for k, v in look["macros"].items()})
    macro["race"] = dict(look["race"])
    basemesh = HumanService.create_human(feet_on_ground=False, macro_detail_dict=macro)
    for name, weight in look["modifiers"]:
        TargetService.load_target(basemesh, TargetService.target_full_path(name), weight=weight, name=name)
    mixed = basemesh.shape_key_add(name="parity_mix", from_mix=True)
    verts.append(np.array([d.co[:] for d in mixed.data], dtype=np.float64))
    basemesh.shape_key_remove(mixed)
    rig = HumanService.add_builtin_rig(basemesh, "game_engine", import_weights=False)
    bones = rig.data.bones
    if bone_names is None:
        bone_names = [b.name for b in bones]
    heads.append(np.array([(rig.matrix_world @ bones[n].head_local)[:] for n in bone_names]))
    tails.append(np.array([(rig.matrix_world @ bones[n].tail_local)[:] for n in bone_names]))
    looks.append(look)
    print(f"PARITY built {i + 1}/{COUNT}")

np.savez(OUT, verts=np.array(verts), heads=np.array(heads), tails=np.array(tails), bone_names=np.array(bone_names),
         looks=np.array(json.dumps(looks)))
print("PARITY saved", OUT)
