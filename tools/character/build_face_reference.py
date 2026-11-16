r"""Blender (headless) + MPFB: a reference human carrying the 52 ARKit face units on its proxies.

Exports, per mesh (body proxy, eyebrows, teeth, tongue): rest positions, per-vertex UV, triangles,
and the 52 shape-key deltas, to an .npz the glb injector reads.
Run with Blender >= 4.2 and the MPFB extension, the "makehuman_system_assets" pack and the "faceunits01"
pack (CC0) installed; MPFB's user data folder is taken from $MPFB_DATA. When MPFB lives in another
Blender version's profile, point Blender at it with BLENDER_USER_RESOURCES, e.g.:

    BLENDER_USER_RESOURCES=~/.config/blender/5.1 \
    MPFB_DATA=~/.config/blender/5.1/extensions/.user/blender_org/mpfb/data \
    blender -b --python tools/character/build_face_reference.py -- /tmp/reference.npz \
        assets_blender/_universe/characters/humanoids/man_ddurieux.mhm
"""
import os
import sys

import bpy
import numpy as np
from bl_ext.blender_org.mpfb.entities.clothes.mhclo import Mhclo
from bl_ext.blender_org.mpfb.services import FaceService, HumanService
from bl_ext.blender_org.mpfb.services.faceservice import ARKIT_FACEUNITS

OUT = sys.argv[sys.argv.index("--") + 1]
DATA = os.path.expanduser(os.environ.get("MPFB_DATA", "~/.config/blender/5.1/extensions/.user/blender_org/mpfb/data"))
ASSETS = {
    "body": (f"{DATA}/proxymeshes/male_muscle_13290/male_muscle_13290.proxy", "Proxymeshes"),
    "eyebrows": (f"{DATA}/eyebrows/eyebrow004/eyebrow004.mhclo", "eyebrows"),
    "teeth": (f"{DATA}/teeth/teeth_base/teeth_base.mhclo", "teeth"),
    "tongue": (f"{DATA}/tongue/tongue01/tongue01.mhclo", "tongue"),
}

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)

MHM = sys.argv[sys.argv.index("--") + 2] if len(sys.argv) > sys.argv.index("--") + 2 else None
objects = {}
if MHM:
    # The character's own human: same macros, proxy and eyebrows; teeth and tongue added on top.
    settings = HumanService.get_default_deserialization_settings()
    settings.update({"subdiv_levels": 0, "load_clothes": False, "override_rig": "NONE", "override_skin_model": "NONE",
                     "clothes_deep_search": False, "bodypart_deep_search": True, "override_clothes_model": "NONE",
                     "override_eyes_model": "NONE"})
    basemesh = HumanService.deserialize_from_mhm(MHM, settings)
    for child in basemesh.parent.children if basemesh.parent else bpy.data.objects:
        print("CHILD", child.name, child.type)
    for key, needle in (("body", "male_muscle_13290"), ("eyebrows", "eyebrow004")):
        objects[key] = next(o for o in bpy.data.objects if needle in o.name and o.type == "MESH")
    for key in ("teeth", "tongue"):
        path, kind = ASSETS[key]
        objects[key] = HumanService.add_mhclo_asset(path, basemesh, asset_type=kind, subdiv_levels=0, material_type="NONE")
else:
    basemesh = HumanService.create_human()
    for key, (path, kind) in ASSETS.items():
        objects[key] = HumanService.add_mhclo_asset(path, basemesh, asset_type=kind, subdiv_levels=0, material_type="NONE")
for key, obj in objects.items():
    print("ASSET", key, obj.name, len(obj.data.vertices))

FaceService.load_targets(basemesh, load_microsoft_visemes=False, load_arkit_faceunits=True)
FaceService.interpolate_targets(basemesh)

keys = basemesh.data.shape_keys.key_blocks
basis = np.array([v.co for v in basemesh.data.vertices])


def interpolate_by_hand(obj, path):
    """The body proxy is a .proxy file, which interpolate_targets may skip: same maths, done here."""
    mhclo = Mhclo()
    mhclo.load(path)
    n = len(obj.data.vertices)
    out = {}
    for name in ARKIT_FACEUNITS:
        delta = np.array([k.co for k in keys[name].data]) - basis
        d = np.zeros((n, 3))
        for vi, m in mhclo.verts.items():
            if vi < n:
                d[vi] = sum(delta[v] * w for v, w in zip(m["verts"], m["weights"]))
        out[name] = d
    return out


def export(obj, key, path):
    mesh = obj.data
    n = len(mesh.vertices)
    rest = np.array([v.co for v in mesh.vertices])
    uv = np.zeros((n, 2))
    if mesh.uv_layers:
        layer = mesh.uv_layers.active.data
        for loop in mesh.loops:
            uv[loop.vertex_index] = layer[loop.index].uv
    mesh.calc_loop_triangles()
    tris = np.array([t.vertices[:] for t in mesh.loop_triangles], dtype=np.int32)
    tri_uv = np.array([[layer[li].uv[:] for li in t.loops] for t in mesh.loop_triangles]) if mesh.uv_layers else None
    sk = mesh.shape_keys.key_blocks if mesh.shape_keys else {}
    deltas = {}
    if all(name in sk for name in ARKIT_FACEUNITS):
        for name in ARKIT_FACEUNITS:
            deltas[name] = np.array([k.co for k in sk[name].data]) - rest
        source = "mpfb"
    else:
        deltas = interpolate_by_hand(obj, path)
        source = "by hand"
    stack = np.stack([deltas[name] for name in ARKIT_FACEUNITS])
    moved = int((np.abs(stack).max(axis=(0, 2)) > 1e-6).sum())
    print(f"EXPORT {key}: {n} verts, {len(tris)} tris, deltas {source}, {moved} verts move")
    return {f"{key}_rest": rest, f"{key}_uv": uv, f"{key}_tris": tris, f"{key}_tri_uv": tri_uv,
            f"{key}_deltas": stack.astype(np.float32)}


arrays = {"names": np.array(ARKIT_FACEUNITS)}
for key, (path, _) in ASSETS.items():
    arrays.update({k: v for k, v in export(objects[key], key, path).items() if v is not None})
np.savez(OUT, **arrays)
print("SAVED", OUT)
