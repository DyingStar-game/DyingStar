"""The body garments are modelled on, as a .blend for the artists (and the dyingstar_garments add-on).

usage: blender -b --python tools/character/garments/export_reference_body.py -- build/character/human_bank.npz \
           <out>/vitruvian_reference.blend

From the bank (build/character/human_bank.npz, see tools/character/vitruvian/README.md):
  - "DS_Body": the game's body in its rest pose (the Vitruvian A pose), every vertex in the bank's order -- a
    garment's refs are these indices --, Blender's frame (Z up, facing -Y), metres, one material per zone, the UVs;
  - shape keys to try a garment on other bodies: Gender_Male / Gender_Female (the body to model on: neutral, a man,
    a woman) and the shapes that move clothes most (fat, thin, muscular, bust, hips...);
  - "DS_Rig": the game's 53 bones on that body, the skin weights as vertex groups, to pose it;
  - vertex group DS_Skin: the skin a garment can hang on;
  - custom properties: ds_body_signature (an exported garment carries it; the game refuses a garment bound to
    another body), ds_reference_version, ds_bone_names (the game's bone order).
"""
import os
import sys

import bmesh
import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import garment_bind as gb  # noqa: E402

REFERENCE_VERSION = 1
PREVIEW_KEYS = [
    "Gender_Male", "Gender_Female",
    "BodyType_Fat", "BodyType_Emaciated", "BodyType_Muscular", "BodyType_Lean", "BodyType_LongProportions",
    "Age_Old", "Chest_Breast_Size", "Waist_Hips_Width", "Waist_GluteSize", "Shoulders_ShoulderWidth",
    "Torso_RibWidth", "Arms_BicepSize", "Arms_Forearm_Girth", "Legs_Thigh_Size", "Legs_Calves_Size",
    "Neck_Girth", "Hands_Size", "Legs_FeetSize",
]
ZONE_COLOURS = {
    "Face": (0.80, 0.62, 0.52), "Torso": (0.80, 0.62, 0.52), "Arms": (0.80, 0.62, 0.52),
    "Legs": (0.80, 0.62, 0.52), "Iris": (0.25, 0.35, 0.45), "Pupil": (0.02, 0.02, 0.02),
    "Sclera_Cornea": (0.9, 0.9, 0.9), "Mouth": (0.6, 0.3, 0.3), "Tearline": (0.9, 0.8, 0.8),
}


def to_blender(p):
    """Game frame (Y up, facing +Z) -> Blender (Z up, facing -Y); the inverse of export_vitruvian.to_game."""
    p = np.asarray(p, dtype=np.float64)
    return np.column_stack([p[:, 0], -p[:, 2], p[:, 1]])


def joints_of(bank, points):
    ptr, idx, w = bank["joint_ptr"], bank["joint_index"], bank["joint_weight"]
    out = np.zeros((len(bank["bone_names"]), 3))
    for b in range(len(out)):
        s, e = ptr[2 * b], ptr[2 * b + 1]
        out[b] = (points[idx[s:e]] * w[s:e, None]).sum(0)
    return out


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    bank_path, out_path = argv[0], os.path.abspath(argv[1])
    bank = dict(np.load(bank_path, allow_pickle=False))
    base = bank["base"].astype(np.float64)
    tris = gb.bank_triangles(bank)
    signature = gb.body_signature(bank["base"], tris)
    zones = [str(z) for z in bank["zone_names"]]
    zone_ptr = bank["zone_index_ptr"]
    tri_zone = np.zeros(len(tris), dtype=np.int64)
    for z in range(len(zones)):
        tri_zone[zone_ptr[z] // 3:zone_ptr[z + 1] // 3] = z
    # body_index is zone-local: the render vertex of a corner is body_index + zone_vertex_ptr
    render = bank["body_index"].astype(np.int64).copy()
    for z in range(len(zones)):
        render[zone_ptr[z]:zone_ptr[z + 1]] += bank["zone_vertex_ptr"][z]
    corner_uv = bank["body_uv"][render].astype(np.float64)
    corner_uv[:, 1] = 1.0 - corner_uv[:, 1]  # the bank's V runs down (Godot), Blender's up

    bpy.ops.wm.read_factory_settings(use_empty=True)
    mesh = bpy.data.meshes.new("DS_Body")
    verts = to_blender(base)
    mesh.vertices.add(len(verts))
    mesh.vertices.foreach_set("co", verts.astype(np.float32).reshape(-1))
    mesh.loops.add(len(tris) * 3)
    mesh.loops.foreach_set("vertex_index", tris.reshape(-1).astype(np.int32))
    mesh.polygons.add(len(tris))
    mesh.polygons.foreach_set("loop_start", np.arange(0, len(tris) * 3, 3, dtype=np.int32))
    mesh.polygons.foreach_set("material_index", tri_zone.astype(np.int32))
    uv = mesh.uv_layers.new(name="UVMap")
    uv.data.foreach_set("uv", corner_uv.astype(np.float32).reshape(-1))
    mesh.update(calc_edges=True)
    mesh.validate(verbose=False)
    for zone in zones:
        mat = bpy.data.materials.new("DS_" + zone)
        mat.diffuse_color = (*ZONE_COLOURS.get(zone, (0.7, 0.7, 0.7)), 1.0)
        mesh.materials.append(mat)

    # quads where the model had them, for the artists' eyes; vertices keep their order (their index is the ref)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.join_triangles(bm, faces=bm.faces[:], cmp_seam=True, cmp_uvs=True, cmp_materials=True,
                             angle_face_threshold=0.7, angle_shape_threshold=0.7)
    bm.to_mesh(mesh)
    bm.free()
    check = np.zeros(len(verts) * 3, dtype=np.float32)
    mesh.vertices.foreach_get("co", check)
    assert len(mesh.vertices) == len(verts) and np.allclose(check.reshape(-1, 3), verts, atol=1e-6), \
        "joining triangles moved vertices: the refs would not match the game's body"

    body = bpy.data.objects.new("DS_Body", mesh)
    bpy.context.scene.collection.objects.link(body)
    body["ds_body_signature"] = signature
    body["ds_reference_version"] = REFERENCE_VERSION
    body["ds_bone_names"] = [str(b) for b in bank["bone_names"]]  # the game's bone order: a garment's bone indices

    body.shape_key_add(name="Basis", from_mix=False)
    names = [str(t) for t in bank["target_names"]]
    for key in PREVIEW_KEYS:
        if key not in names:
            print("no target", key)
            continue
        shaped = to_blender(gb.morph(bank, {key: 1.0}))
        block = body.shape_key_add(name=key, from_mix=False)
        block.data.foreach_set("co", shaped.astype(np.float32).reshape(-1))
        block.slider_min, block.slider_max = 0.0, 1.0
        block.value = 0.0  # Blender starts a new key at 1

    skin = np.zeros(len(verts), dtype=bool)
    for z, zone in enumerate(zones):
        if zone in gb.SKIN_ZONES:
            skin[bank["body_vertex"][bank["zone_vertex_ptr"][z]:bank["zone_vertex_ptr"][z + 1]]] = True
    group = body.vertex_groups.new(name="DS_Skin")
    group.add(np.nonzero(skin)[0].tolist(), 1.0, "REPLACE")

    bone_names = [str(b) for b in bank["bone_names"]]
    parents = [str(p) for p in bank["bone_parents"]]
    aims = bank["bone_aim"].tolist()
    joints = to_blender(joints_of(bank, base))
    arm_data = bpy.data.armatures.new("DS_Rig")
    rig = bpy.data.objects.new("DS_Rig", arm_data)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    edit = {}
    for b, name in enumerate(bone_names):
        eb = arm_data.edit_bones.new(name)
        head = joints[b]
        if aims[b] >= 0 and np.linalg.norm(joints[aims[b]] - head) > 1e-4:
            tail = joints[aims[b]]
        else:
            p = bone_names.index(parents[b]) if parents[b] in bone_names else -1
            direction = head - joints[p] if p >= 0 and np.linalg.norm(head - joints[p]) > 1e-4 else np.array([0, 0, 1.0])
            tail = head + direction / np.linalg.norm(direction) * 0.05
        eb.head, eb.tail = head.tolist(), tail.tolist()
        edit[name] = eb
    for b, name in enumerate(bone_names):
        if parents[b] in edit:
            edit[name].parent = edit[parents[b]]
    bpy.ops.object.mode_set(mode="OBJECT")

    sb, sw = bank["skin_bones"], bank["skin_weights"]
    for b, name in enumerate(bone_names):
        rows, cols = np.nonzero((sb == b) & (sw > 0))
        if not len(rows):
            continue
        vg = body.vertex_groups.new(name=name)
        for w in np.unique(np.round(sw[rows, cols], 4)):
            pick = rows[np.round(sw[rows, cols], 4) == w]
            vg.add(pick.tolist(), float(w), "REPLACE")
    body.parent = rig
    mod = body.modifiers.new("Armature", "ARMATURE")
    mod.object = rig

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=out_path, compress=True)
    print("reference body %s: %d vertices, %d faces, %d shape keys, %d bones -> %s"
          % (signature, len(mesh.vertices), len(mesh.polygons), len(body.data.shape_keys.key_blocks) - 1,
             len(bone_names), out_path))


main()
