"""Export the Vitruvian Project human (CC0) from its .blend into a raw .npz, in Blender.

Everything later steps need, untouched: the neutral mesh (no modifier, no subdivision), its quads,
material zones and UVs, every shape key as a sparse delta, the skin weights of its deform bones, the
rig's rest bones, and the eyebrow / eyelash strands. Coordinates are converted to the game's frame:
metres, Y up, the body facing +Z (Blender: Z up, facing -Y  ->  (x, z, -y)).

usage: blender -b VitruvianProject142Pack.blend --python export_vitruvian.py -- out.npz
"""
import sys

import bpy
import numpy as np

OUT = sys.argv[sys.argv.index("--") + 1]
BODY = "Vitruvian"
BROWS = "Vitruvian-EyeBrows"
LASHES = "Eyelashes"
UV_LAYER = "VitruvianUV"
MOVE_EPS = 1e-6  # m: a shape key moving a vertex less than this does not list it


def to_game(a: np.ndarray) -> np.ndarray:
    return np.stack([a[..., 0], a[..., 2], -a[..., 1]], axis=-1)


body = bpy.data.objects[BODY]
mesh = body.data
world = np.array(body.matrix_world)
keys = mesh.shape_keys.key_blocks
n = len(mesh.vertices)


def key_coords(block) -> np.ndarray:
    flat = np.empty(n * 3, dtype=np.float64)
    block.data.foreach_get("co", flat)
    local = flat.reshape(-1, 3)
    return local @ world[:3, :3].T + world[:3, 3]


neutral = key_coords(keys[0])
out = {"verts": to_game(neutral).astype(np.float32)}

# --- topology, zones, UVs ---------------------------------------------------------------------------------
loops = np.empty(len(mesh.loops), dtype=np.int32)
mesh.loops.foreach_get("vertex_index", loops)
starts = np.empty(len(mesh.polygons), dtype=np.int32)
totals = np.empty(len(mesh.polygons), dtype=np.int32)
zones = np.empty(len(mesh.polygons), dtype=np.int32)
mesh.polygons.foreach_get("loop_start", starts)
mesh.polygons.foreach_get("loop_total", totals)
mesh.polygons.foreach_get("material_index", zones)
assert (totals == 4).all(), "the Vitruvian mesh is all quads"
uv = np.empty(len(mesh.loops) * 2, dtype=np.float64)
mesh.uv_layers[UV_LAYER].data.foreach_get("uv", uv)
out["quads"] = loops[starts[:, None] + np.arange(4)[None, :]]
out["quad_uv"] = uv.reshape(-1, 2)[starts[:, None] + np.arange(4)[None, :]].astype(np.float32)
out["quad_zone"] = zones
out["zone_names"] = np.array([m.name if m else "" for m in mesh.materials])

# --- shape keys ---------------------------------------------------------------------------------------------
names, lo, hi, ptr, index, delta = [], [], [], [0], [], []
for block in list(keys)[1:]:
    assert block.relative_key == keys[0], f"{block.name} is not relative to the neutral"
    d = to_game(key_coords(block) - neutral)
    moved = np.nonzero(np.abs(d).max(axis=1) > MOVE_EPS)[0]
    names.append(block.name)
    lo.append(block.slider_min)
    hi.append(block.slider_max)
    index.append(moved.astype(np.int32))
    delta.append(d[moved].astype(np.float32))
    ptr.append(ptr[-1] + len(moved))
out.update({"key_names": np.array(names), "key_min": np.array(lo, np.float32), "key_max": np.array(hi, np.float32),
            "key_ptr": np.array(ptr, np.int64), "key_index": np.concatenate(index), "key_delta": np.concatenate(delta)})

# --- skin weights -------------------------------------------------------------------------------------------
group_names = [g.name for g in body.vertex_groups]
rows, cols, vals = [], [], []
for v in mesh.vertices:
    for g in v.groups:
        if g.weight > 0.0:
            rows.append(v.index)
            cols.append(g.group)
            vals.append(g.weight)
out.update({"group_names": np.array(group_names), "weight_vertex": np.array(rows, np.int32),
            "weight_group": np.array(cols, np.int32), "weight_value": np.array(vals, np.float32)})

# --- rig rest bones -----------------------------------------------------------------------------------------
rig = body.parent
rig_world = np.array(rig.matrix_world)
bones = list(rig.data.bones)
heads = np.array([b.head_local[:] for b in bones]) @ rig_world[:3, :3].T + rig_world[:3, 3]
tails = np.array([b.tail_local[:] for b in bones]) @ rig_world[:3, :3].T + rig_world[:3, 3]
out.update({"bone_names": np.array([b.name for b in bones]), "bone_parent": np.array([b.parent.name if b.parent else "" for b in bones]),
            "bone_head": to_game(heads).astype(np.float32), "bone_tail": to_game(tails).astype(np.float32),
            "bone_deform": np.array([b.use_deform for b in bones])})

# --- eyebrows (particle hair: parent strands per style) and eyelashes (curves) ----------------------------
# Each style is a particle system of the brows object, and only the one whose modifier shows is evaluated
# (the others read as zeros): show them one at a time.
brow_object = bpy.data.objects[BROWS]
brow_modifiers = [m for m in brow_object.modifiers if m.type == "PARTICLE_SYSTEM"]
shown = [m.show_viewport for m in brow_modifiers]
style_names, style_ptr, strand_ptr, points = [], [0], [0], []
for modifier in brow_modifiers:
    for other in brow_modifiers:
        other.show_viewport = other == modifier
    depsgraph = bpy.context.evaluated_depsgraph_get()
    depsgraph.update()
    brows = brow_object.evaluated_get(depsgraph)
    brow_world = np.array(brows.matrix_world)
    system = brows.particle_systems[modifier.particle_system.name]
    evaluated_modifier = brows.modifiers[modifier.name]
    count = 0
    for particle in system.particles:
        pts = np.array([k.co_object(brows, evaluated_modifier, particle)[:] for k in particle.hair_keys])
        if len(pts) < 2 or np.abs(pts).sum() < 1e-9:
            continue
        points.append(to_game(pts @ brow_world[:3, :3].T + brow_world[:3, 3]))
        strand_ptr.append(strand_ptr[-1] + len(pts))
        count += 1
    style_names.append(system.name)
    style_ptr.append(style_ptr[-1] + count)
for modifier, was in zip(brow_modifiers, shown):
    modifier.show_viewport = was
out.update({"brow_styles": np.array(style_names), "brow_style_ptr": np.array(style_ptr, np.int32),
            "brow_strand_ptr": np.array(strand_ptr, np.int32),
            "brow_points": np.concatenate(points).astype(np.float32) if points else np.zeros((0, 3), np.float32)})

lashes = bpy.data.objects[LASHES]
lash_world = np.array(lashes.matrix_world)
lash_points = np.empty(len(lashes.data.points) * 3, dtype=np.float64)
lashes.data.attributes["position"].data.foreach_get("vector", lash_points)
offsets = np.array([c.first_point_index for c in lashes.data.curves] + [len(lashes.data.points)], dtype=np.int32)
out.update({"lash_points": to_game(lash_points.reshape(-1, 3) @ lash_world[:3, :3].T + lash_world[:3, 3]).astype(np.float32),
            "lash_ptr": offsets})

np.savez_compressed(OUT, **out)
print(f"EXPORT {n} vertices, {len(out['quads'])} quads, {len(names)} shape keys, {len(group_names)} groups, "
      f"{len(bones)} bones, {len(style_names)} brow styles ({strand_ptr.__len__() - 1} strands), {len(offsets) - 1} lashes -> {OUT}")
