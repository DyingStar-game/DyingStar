"""Build the character bank from the Vitruvian export (export_vitruvian.py's .npz).

Same .npz layout as the MakeHuman bank it replaces (pack_human_bank.tscn packs it into human_bank.res),
with what the Vitruvian body brings or needs:

  targets       every shape key, by its own name: morphology sliders, gender / origin / age, FACS face units
  zones         the render mesh is cut by material zone (Face, Torso, Arms, Legs, eyes, mouth...): each has
                its own textures. Render vertices are ordered by zone; a zone's triangles index its own range
  joints        the game skeleton keeps its 53 humanoid bones. Each joint is an AFFINE combination of the
                mesh vertices around it (weights summing to 1, exact on the neutral body), so it follows any
                shape; MakeHuman had joint cubes, Vitruvian has none
  bone_aim      the child each bone points at. Vitruvian rests in an A pose, the game skeleton and its
                animations in a T pose: the builder turns each bone from its A direction to the template's
                (in the skin binds, as Godot's glTF importer does), which needs to know where a bone points
  skin          Rigify's deform bones merged onto the 53

Also writes the small catalogue the game reads WITHOUT the bank (the dedicated server validates
appearances with it): assets/_universe/characters/human/human_catalogue.json.

usage: python3 build_vitruvian_bank.py vitruvian_raw.npz out.npz <project root>
"""
import json
import os
import sys

import numpy as np
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "human_bank"))
from build_human_bank import tangents, top4, vertex_normals  # noqa: E402

DENSE_FRACTION = 0.6
JOINT_NEIGHBOURS = 48

# Game bone -> (parent, Rigify bone whose head is the joint, bone it points at in the A pose or "")
SIDES = (("Left", "L"), ("Right", "R"))
BONES = [("Root", "", None, ""), ("Hips", "Root", "DEF-spine", ""), ("Spine", "Hips", "DEF-spine.001", "Chest"),
         ("Chest", "Spine", "DEF-spine.002", "UpperChest"), ("UpperChest", "Chest", "DEF-spine.003", "Neck"),
         ("Neck", "UpperChest", "DEF-spine.004", "Head"), ("Head", "Neck", "DEF-spine.006", "")]
FINGERS = (("Thumb", "thumb", ("Metacarpal", "Proximal", "Distal")), ("Index", "f_index", ("Proximal", "Intermediate", "Distal")),
           ("Middle", "f_middle", ("Proximal", "Intermediate", "Distal")), ("Ring", "f_ring", ("Proximal", "Intermediate", "Distal")),
           ("Little", "f_pinky", ("Proximal", "Intermediate", "Distal")))
for side, s in SIDES:
    BONES += [(f"{side}Shoulder", "UpperChest", f"DEF-shoulder.{s}", f"{side}UpperArm"),
              (f"{side}UpperArm", f"{side}Shoulder", f"DEF-upper_arm.{s}", f"{side}LowerArm"),
              (f"{side}LowerArm", f"{side}UpperArm", f"DEF-forearm.{s}", f"{side}Hand"),
              (f"{side}Hand", f"{side}LowerArm", f"DEF-hand.{s}", f"{side}MiddleProximal"),
              (f"{side}UpperLeg", "Hips", f"DEF-thigh.{s}", f"{side}LowerLeg"),
              (f"{side}LowerLeg", f"{side}UpperLeg", f"DEF-shin.{s}", f"{side}Foot"),
              (f"{side}Foot", f"{side}LowerLeg", f"DEF-foot.{s}", f"{side}Toes"),
              (f"{side}Toes", f"{side}Foot", f"DEF-toe.{s}", "")]
    for finger, rig, parts in FINGERS:
        for k, part in enumerate(parts):
            BONES.append((f"{side}{finger}{part}", f"{side}{finger}{parts[k - 1]}" if k else f"{side}Hand",
                          f"DEF-{rig}.{k + 1:02d}.{s}", f"{side}{finger}{parts[k + 1]}" if k < 2 else ""))

# Rigify deform group -> game bone (prefix match, longest first); anything unweighted goes to the head.
GROUP_TO_BONE = [("DEF-spine.006", "Head"), ("DEF-spine.005", "Neck"), ("DEF-spine.004", "Neck"), ("DEF-spine.003", "UpperChest"),
                 ("DEF-spine.002", "Chest"), ("DEF-spine.001", "Spine"), ("DEF-spine", "Hips"), ("DEF-abdomen", "Spine"),
                 ("DEF-chest_expand", "UpperChest"), ("DEF-breast", "UpperChest"), ("DEF-pelvis", "Hips")]
for side, s in SIDES:
    GROUP_TO_BONE += [(f"DEF-shoulder.{s}", f"{side}Shoulder"), (f"DEF-upper_arm.{s}", f"{side}UpperArm"),
                      (f"DEF-forearm.{s}", f"{side}LowerArm"), (f"DEF-hand.{s}", f"{side}Hand"), (f"DEF-palm", f"?Hand"),
                      (f"DEF-thigh.{s}", f"{side}UpperLeg"), (f"DEF-thigh-medial.{s}", f"{side}UpperLeg"),
                      (f"DEF-thigh-lateral.{s}", f"{side}UpperLeg"), (f"DEF-knee.{s}", f"{side}LowerLeg"),
                      (f"DEF-shin.{s}", f"{side}LowerLeg"), (f"DEF-foot.{s}", f"{side}Foot"), (f"DEF-toe_bend.{s}", f"{side}Toes"),
                      (f"DEF-big_toe", "?Toes")]
    for finger, rig, parts in FINGERS:
        for k, part in enumerate(parts):
            GROUP_TO_BONE.append((f"DEF-{rig}.{k + 1:02d}.{s}", f"{side}{finger}{part}"))

SKIN_ZONES = ("Face", "Torso", "Arms", "Legs")
ORIGINS = ("Race_African", "Race_EastAsian", "Race_White", "Race_Hispanic", "Race_MiddleEastern", "Race_Bengali", "Race_Tamil",
           "Race_Punjabi", "Race_Marathi", "Race_Telegu", "Race_Sinhalese", "Race_Kannada")
SHAPE_KEYS = ("BodyType_Fat", "BodyType_Emaciated", "BodyType_Muscular", "BodyType_Lean", "BodyType_LongProportions")
NOT_SLIDERS = ("Gender_", "Race_", "Age_", "Fantasy_", "FACS_", "Mouth_NoTeeth")
EYE_COLOURS = ("brown", "brownlight", "green", "bluegreen", "blue", "lightblue", "deepblue", "grey", "ice")
TABS = (("BodyType_", "shape"), ("Generic_", "head"), ("Head_", "head"), ("Neck_", "head"), ("Face_", "head"),
        ("Eyes_", "eyes"), ("Eye_", "eyes"), ("Nose_", "nose"), ("Mouth_", "mouth"), ("Chin_", "jaw"), ("Jaw_", "jaw"),
        ("Cheeks_", "jaw"), ("Ear_", "ears"), ("Ears_", "ears"), ("Shoulders_", "torso"), ("Torso_", "torso"),
        ("Chest_", "torso"), ("Stomach_", "torso"), ("Waist_", "hips"), ("Arms_", "arms"), ("Hands_", "arms"), ("Legs_", "legs"))


def group_bone(group: str) -> str:
    side = "Left" if group.endswith(".L") or ".L." in group else "Right"
    for prefix, bone in sorted(GROUP_TO_BONE, key=lambda p: -len(p[0])):
        if group == prefix or group.startswith(prefix + ".") or (bone.startswith("?") and group.startswith(prefix)):
            return bone.replace("?", side)
    return ""


def affine_weights(points: np.ndarray, target: np.ndarray) -> np.ndarray:
    """Weights w (sum 1, w . points = target) closest to uniform: the joint as an affine combination."""
    k = len(points)
    a = np.vstack([points.T, np.ones(k)])
    b = np.append(target, 1.0)
    u = np.full(k, 1.0 / k)
    return u + a.T @ np.linalg.solve(a @ a.T + 1e-12 * np.eye(4), b - a @ u)


def main():
    raw = np.load(sys.argv[1], allow_pickle=False)
    out_path = sys.argv[2]
    verts = raw["verts"].astype(np.float64)
    n = len(verts)
    arrays = {"keep": np.arange(n, dtype=np.int32), "base": verts.astype(np.float32)}

    # --- targets -------------------------------------------------------------------------------------------
    key_names = [str(k) for k in raw["key_names"]]
    ptr = raw["key_ptr"]
    names, scales, starts, counts, dense_flags, sparse_idx, deltas = [], [], [], [], [], [], []
    cursor = 0
    for i, key in enumerate(key_names):
        idx = raw["key_index"][ptr[i]:ptr[i + 1]]
        d = raw["key_delta"][ptr[i]:ptr[i + 1]].astype(np.float64)
        peak = float(np.abs(d).max()) if len(d) else 0.0
        scale = peak / 32767.0 if peak > 0 else 1.0
        q = np.round(d / scale).astype(np.int16)
        dense = len(idx) > DENSE_FRACTION * n
        names.append(key)
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
            deltas.append(q.reshape(-1))
            cursor += len(idx) * 3
    sparse_start, run = [], 0
    for dense, count in zip(dense_flags, counts):
        sparse_start.append(-1 if dense else run)
        run += 0 if dense else count
    face_units = [k for k in key_names if k.startswith("FACS_")]
    catalogue = []
    for i, key in enumerate(key_names):
        if key.startswith(NOT_SLIDERS):
            continue
        tab = next((t for prefix, t in TABS if key.startswith(prefix)), "head")
        catalogue.append({"key": key, "tab": tab, "label": "%%CHAR_MOD_" + key.upper(), "unipolar": bool(raw["key_min"][i] >= 0.0),
                          "signed": True, "negative": [], "positive": [key]})
    assets = {"hair": [{"id": "none", "gender": "any"}], "eyebrows": [], "eyelashes": [], "beard": [], "outfit": []}
    macro = {"version": 2, "female": "Gender_Female", "male": "Gender_Male", "old": "Age_Old", "origins": list(ORIGINS)}
    arrays.update({
        "target_names": np.array(names), "target_scale": np.array(scales, dtype=np.float32),
        "target_delta_start": np.array(starts, dtype=np.int32), "target_count": np.array(counts, dtype=np.int32),
        "target_dense": np.array(dense_flags, dtype=np.uint8), "target_sparse_start": np.array(sparse_start, dtype=np.int32),
        "sparse_index": np.concatenate(sparse_idx), "delta": np.concatenate(deltas).astype(np.int16),
        "face_units": np.array(face_units), "beard_mask": np.zeros((n, 4), dtype=np.uint8),
        "macro_json": np.array(json.dumps(macro)), "catalogue_json": np.array(json.dumps(catalogue)),
        "assets_json": np.array(json.dumps(assets)),
    })
    if len(sys.argv) > 3:
        runtime = {
            "_doc": "Generated by tools/character/vitruvian/build_vitruvian_bank.py: never edit by hand. Append-only "
                    "lists; an appearance stores positions in them.",
            "modifiers": [{"key": c["key"], "tab": c["tab"], "label": c["label"], "unipolar": c["unipolar"]} for c in catalogue],
            "assets": assets, "eye_colours": list(EYE_COLOURS), "origins": list(ORIGINS),
            "origin_labels": ["%%CHAR_ORIGIN_" + o.removeprefix("Race_").upper() for o in ORIGINS],
        }
        with open(os.path.join(sys.argv[3], "assets/_universe/characters/human/human_catalogue.json"), "w") as f:
            json.dump(runtime, f, indent=1)
    print(f"targets: {len(names)} ({sum(dense_flags)} dense), {cursor // 3} deltas, {len(catalogue)} sliders, {len(face_units)} face units")

    # --- skeleton ------------------------------------------------------------------------------------------
    rig = {str(b): i for i, b in enumerate(raw["bone_names"])}
    bone_names = [b[0] for b in BONES]
    tree = cKDTree(verts)
    joint_ptr, joint_idx, joint_w, worst = [0], [], [], 0.0
    joint_pos = {}
    for name, _parent, source, _aim in BONES:
        target = raw["bone_head"][rig[source]].astype(np.float64) if source else np.array([0.0, verts[:, 1].min(), 0.0])
        _dist, near = tree.query(target, k=JOINT_NEIGHBOURS)
        w = affine_weights(verts[near], target)
        worst = max(worst, float(np.linalg.norm(w @ verts[near] - target)))
        joint_pos[name] = target
        joint_idx.extend(near.tolist())
        joint_w.extend(w.tolist())
        joint_ptr.extend([len(joint_idx), len(joint_idx)])  # head run, then an empty tail run
    arrays.update({
        "bone_names": np.array(bone_names), "bone_parents": np.array([b[1] for b in BONES]),
        "bone_aim": np.array([bone_names.index(b[3]) if b[3] else -1 for b in BONES], dtype=np.int32),
        "joint_ptr": np.array(joint_ptr, dtype=np.int32), "joint_index": np.array(joint_idx, dtype=np.int32),
        "joint_weight": np.array(joint_w, dtype=np.float32),
    })
    print(f"joints: {len(BONES)} bones, neutral error {worst * 1000:.4f} mm, hips at {joint_pos['Hips'][1]:.3f} m")

    # --- skin ----------------------------------------------------------------------------------------------
    dense_w = np.zeros((n, len(bone_names)))
    unknown = set()
    for g, group in enumerate(str(x) for x in raw["group_names"]):
        bone = group_bone(group) if group.startswith("DEF-") else ""
        if not bone:
            if group.startswith("DEF-"):
                unknown.add(group)
            continue
        sel = raw["weight_group"] == g
        np.add.at(dense_w[:, bone_names.index(bone)], raw["weight_vertex"][sel], raw["weight_value"][sel])
    if unknown:
        sys.exit(f"deform groups with no game bone: {sorted(unknown)}")
    loose = dense_w.sum(1) <= 1e-6
    dense_w[loose, bone_names.index("Head")] = 1.0  # eyes, teeth, tongue: no group, they ride the head
    bones4, weights4 = top4(dense_w)
    feet = [bone_names.index(b) for b in bone_names if b.endswith(("Foot", "Toes"))]
    soles = np.nonzero((dense_w[:, feet].sum(1) > 0.5) & (verts[:, 1] < 0.06))[0]
    arrays.update({"skin_bones": bones4, "skin_weights": weights4, "sole_vertex": soles.astype(np.int32)})
    print(f"skin: {int(loose.sum())} unweighted vertices on the head, {len(soles)} sole vertices")

    # --- render mesh, by zone ------------------------------------------------------------------------------
    zone_names = [str(z) for z in raw["zone_names"]]
    order = [z for z in SKIN_ZONES if z in zone_names] + [z for z in zone_names if z not in SKIN_ZONES]
    src, uvs, index, zone_vertex_ptr, zone_index_ptr, used = [], [], [], [0], [0], []
    for zone in order:
        z = zone_names.index(zone)
        quads = raw["quads"][raw["quad_zone"] == z]
        quv = raw["quad_uv"][raw["quad_zone"] == z]
        if len(quads) == 0:
            continue
        lookup, base = {}, len(src)
        for q, t in zip(quads, quv):
            corner = []
            for v, (u, w) in zip(q.tolist(), t.tolist()):
                key = (v, round(u, 6), round(w, 6))
                if key not in lookup:
                    lookup[key] = len(src) - base
                    src.append(v)
                    uvs.append((u, 1.0 - w))
                corner.append(lookup[key])
            index.extend([corner[0], corner[1], corner[2], corner[0], corner[2], corner[3]])
        used.append(zone)
        zone_vertex_ptr.append(len(src))
        zone_index_ptr.append(len(index))
        print(f"zone {zone:14s}: {len(src) - base:6d} render vertices, {len(quads) * 2:6d} triangles, "
              f"uv {quv.min():.3f}..{quv.max():.3f}")
    src = np.array(src, dtype=np.int64)
    uvs = np.array(uvs, dtype=np.float32)
    index = np.array(index, dtype=np.int32)
    # normals and tangents over the whole welded mesh: global indices for that
    global_index = index.copy()
    for z in range(len(used)):
        global_index[zone_index_ptr[z]:zone_index_ptr[z + 1]] += zone_vertex_ptr[z]
    weld_tris = src[global_index]
    normals = vertex_normals(verts, weld_tris.astype(np.int32))[src]
    arrays.update({
        "body_vertex": src.astype(np.int32), "body_uv": uvs, "body_index": index,
        "body_tangent": tangents(verts[src], normals, uvs, global_index),
        "zone_names": np.array(used), "zone_vertex_ptr": np.array(zone_vertex_ptr, dtype=np.int32),
        "zone_index_ptr": np.array(zone_index_ptr, dtype=np.int32),
    })
    arrays["asset_meta_json"] = np.array(json.dumps([]))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    np.savez_compressed(out_path, **arrays)
    print(f"wrote {out_path}: {os.path.getsize(out_path) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
