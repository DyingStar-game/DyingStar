"""RETIRED as a script: the game's body is now the Vitruvian one (tools/character/vitruvian). Kept for its mesh
helpers (render_mesh, tangents, vertex_normals, top4, bone_profile_map, triangulate), which the Vitruvian
tools import. What it did: build the character bank a MakeHuman body was baked from at runtime.

Output: one .npz (then packed into a Godot .res by pack_human_bank.tscn) holding, in a COMPACT vertex
space (only the basemesh vertices the game uses: the body, the joint cubes and the helpers the chosen
assets hang on), in metres and MakeHuman's frame (= Godot's: Y up, facing +Z):

  base            (K, 3) float32   rest positions
  keep            (K,)   int32     original basemesh index of each compact vertex
  targets         every macro combination and every slider target the creator can reach: a per-target
                  int16 quantisation scale, and either a sparse (uint16 index, int16 x3) list or, for
                  targets touching most vertices, a dense int16 x3 block
  macro_json      MakeHuman's macro "parts" (macrodetails/macro.json), for the runtime macro rule
  joints          per game_engine bone: the compact vertices whose mean is its head / tail
  body render     triangles of the visible body (quads split), one render vertex per (vertex, UV) pair,
                  reference tangents, 4 skin bones per vertex
  assets          per asset: 3 compact refs + weights + offsets per vertex, axis scale pairs, its render
                  mesh, skin bones interpolated from the body, and the body vertices it hides

usage: python3 build_human_bank.py out.npz [--import man_ddurieux.glb.import]
  The .import file maps game_engine bone names to the Godot humanoid profile names the game's skeleton
  uses; without it the game_engine names are kept.
"""
import json
import os
import re
import sys

import numpy as np
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mh_formats  # noqa: E402
from human_model import DEFAULT_USER, HumanModel  # noqa: E402

EXCLUDED_TARGET_DIRS = ("expression", "asym", "genitals")
FACE_UNITS_DIR = "targets/faceunits"  # the 52 ARKit face units (MPFB "faceunits01" pack, CC0)
DENSE_FRACTION = 0.6  # a target moving more than this share of the vertices is stored dense
MOVE_EPS = 1e-6  # decimetres: smaller deltas are dropped


def bone_profile_map(import_path: str) -> dict:
    if not import_path:
        return {}
    text = open(import_path).read()
    return {ge: prof for prof, ge in re.findall(r'"bone_map/(\w+)":&"(\w*)"', text) if ge}


def macro_target_keys(model: HumanModel) -> list:
    """Every macro combination file (macrodetails/** and breast/*), minus baby ones (age >= 18)."""
    keys = []
    for key, path in model._paths.items():
        if "/" not in key or not path.startswith(model.targets_dir):
            continue
        top = key.split("/")[0]
        if top in ("macrodetails", "breast") and "baby" not in key:
            keys.append(key)
    return sorted(keys)


def triangulate(faces):
    tris = []
    for vi, ti in faces:
        for k in range(1, len(vi) - 1):
            tris.append(((vi[0], vi[k], vi[k + 1]), (ti[0], ti[k], ti[k + 1])))
    return tris


def render_mesh(tris, uvs):
    """Split vertices at UV seams: one render vertex per (vertex, uv) pair. Returns (src vertex, uv, indices)."""
    lookup, src, uv, index = {}, [], [], []
    for vtri, ttri in tris:
        for v, t in zip(vtri, ttri):
            key = (v, t)
            if key not in lookup:
                lookup[key] = len(src)
                src.append(v)
                uv.append(uvs[t] if t >= 0 else (0.0, 0.0))
            index.append(lookup[key])
    uv = np.array(uv, dtype=np.float32)
    uv[:, 1] = 1.0 - uv[:, 1]  # OBJ V runs up, Godot's down
    return np.array(src, dtype=np.int64), uv, np.array(index, dtype=np.int32)


def tangents(pos, normal_src, uv, index):
    """Per-vertex tangent (xyz + handedness) accumulated from the triangles' UV gradients."""
    n = len(pos)
    tan, bit = np.zeros((n, 3)), np.zeros((n, 3))
    tri = index.reshape(-1, 3)
    p0, p1, p2 = pos[tri[:, 0]], pos[tri[:, 1]], pos[tri[:, 2]]
    w0, w1, w2 = uv[tri[:, 0]], uv[tri[:, 1]], uv[tri[:, 2]]
    e1, e2 = p1 - p0, p2 - p0
    d1, d2 = w1 - w0, w2 - w0
    r = d1[:, 0] * d2[:, 1] - d2[:, 0] * d1[:, 1]
    r = np.where(np.abs(r) < 1e-12, 1e-12, r)
    t = (e1 * d2[:, 1:2] - e2 * d1[:, 1:2]) / r[:, None]
    b = (e2 * d1[:, 0:1] - e1 * d2[:, 0:1]) / r[:, None]
    for c in range(3):
        np.add.at(tan, tri[:, c], t)
        np.add.at(bit, tri[:, c], b)
    nrm = normal_src
    tan -= nrm * (tan * nrm).sum(1, keepdims=True)
    tan /= np.maximum(np.linalg.norm(tan, axis=1, keepdims=True), 1e-12)
    hand = np.sign((np.cross(nrm, tan) * bit).sum(1))
    hand[hand == 0] = 1.0
    return np.column_stack([tan, hand]).astype(np.float32)


def vertex_normals(pos, index):
    tri = index.reshape(-1, 3)
    fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    out = np.zeros_like(pos)
    for c in range(3):
        np.add.at(out, tri[:, c], fn)
    return out / np.maximum(np.linalg.norm(out, axis=1, keepdims=True), 1e-12)


def top4(dense_weights: np.ndarray):
    """(n, bones) -> 4 strongest bone indices and their renormalised weights."""
    order = np.argsort(-dense_weights, axis=1)[:, :4]
    w = np.take_along_axis(dense_weights, order, axis=1)
    s = w.sum(1, keepdims=True)
    w = np.where(s > 0, w / np.maximum(s, 1e-12), np.array([1.0, 0, 0, 0]))
    return order.astype(np.uint8), w.astype(np.float32)


def face_unit_keys(model: HumanModel) -> list:
    """The ARKit face units, "faceunits/<name>" in ARKit's alphabetical order (52 when the pack is there)."""
    folder = os.path.join(DEFAULT_USER, FACE_UNITS_DIR)
    names = sorted(f.split(".target")[0] for f in os.listdir(folder) if ".target" in f) if os.path.isdir(folder) else []
    for name in names:
        model._paths["faceunits/" + name] = os.path.join(folder, name + ".target")
    return ["faceunits/" + name for name in names]


def _smooth(x0, x1, v):
    t = np.clip((v - x0) / (x1 - x0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def beard_masks(model: HumanModel) -> np.ndarray:
    """Per basemesh vertex, where each beard grows, 0..1: (full beard, moustache, goatee, 0).

    Drawn on the REST basemesh (decimetres) from landmarks the face units give -- the lips are what
    mouthRoll moves, the chin the bottom of what jawOpen moves, the nose tip the face's most forward
    point -- so the masks are indexed by vertex and follow every body shape. Smooth edges; the skin
    shader turns them into hair (CharacterAppearance.beard picks the style)."""
    verts = model.base.verts
    body = model.base.group_verts["body"]

    def moved(name):
        idx, delta = model.target("faceunits/" + name)
        out = np.zeros(len(verts))
        out[idx] = np.linalg.norm(delta, axis=1)
        return out

    p = verts[body]
    x, y, z = np.abs(p[:, 0]), p[:, 1], p[:, 2]
    head = y > 6.0
    subnasale = p[head][np.argmax(p[head][:, 2]), 1] - 0.11
    lips = body[(moved("mouthRollLower") + moved("mouthRollUpper"))[body] > 0.05]
    mouth_bottom = verts[lips][:, 1].min()
    jaw = body[moved("jawOpen")[body] > 1e-3]
    chin = verts[jaw[np.abs(verts[jaw][:, 0]) < 0.2]][:, 1].min()
    lip_distance = cKDTree(verts[lips]).query(p)[0]
    no_lips = _smooth(0.02, 0.07, lip_distance)
    # the moustache keeps the philtrum, which mouthRollUpper also moves: only the red of the lip is out
    vermilion = lips[verts[lips][:, 1] < subnasale - 0.08]
    no_vermilion = _smooth(0.015, 0.05, cKDTree(verts[vermilion]).query(p)[0])
    not_ears = _smooth(0.74, 0.66, x)
    # full beard: what jawOpen moves (chin, jaw, lower cheeks -- it stops at the jaw line, so the neck
    # under the ears stays bare), up to the cheekbone line, with sideburns before the ears and a short
    # band under the chin
    jaw_area = _smooth(0.002, 0.03, moved("jawOpen")[body])
    top = subnasale + 0.02 + 0.5 * _smooth(0.42, 0.68, x)
    sideburns = _smooth(0.5, 0.58, x) * _smooth(7.4, 7.25, y) * _smooth(6.4, 6.6, y) * _smooth(0.15, 0.3, z) * _smooth(0.85, 0.7, z)
    under_chin = (_smooth(chin - 0.07, chin + 0.01, y) * _smooth(chin + 0.25, chin + 0.1, y) * _smooth(0.4, 0.6, z)
                  * _smooth(0.4, 0.3, x))
    full = np.maximum(np.maximum(jaw_area * _smooth(top + 0.04, top - 0.08, y), sideburns), under_chin)
    full = full * not_ears * no_lips
    low = subnasale - 0.12 - 0.28 * _smooth(0.08, 0.32, x)
    moustache = (_smooth(low - 0.04, low + 0.02, y) * _smooth(subnasale + 0.03, subnasale - 0.02, y)
                 * _smooth(0.38, 0.28, x) * _smooth(1.15, 1.35, z) * no_vermilion)
    goatee = (_smooth(mouth_bottom + 0.02, mouth_bottom - 0.06, y) * _smooth(chin - 0.12, chin + 0.02, y)
              * _smooth(0.42, 0.3, x) * _smooth(0.7, 1.0, z) * no_lips)
    out = np.zeros((len(verts), 4))
    out[body, 0], out[body, 1], out[body, 2] = full, moustache, goatee
    return out


def main():
    out_path = sys.argv[1]
    import_path = sys.argv[sys.argv.index("--import") + 1] if "--import" in sys.argv else ""
    model = HumanModel()
    profile = bone_profile_map(import_path)
    catalogue = mh_formats.load_json(os.path.join(HERE, "catalogue.json"))["modifiers"]
    asset_cfg = mh_formats.load_json(os.path.join(HERE, "assets.json"))

    # --- assets first: they decide which helper vertices must be kept --------------------------
    assets = []
    for kind, entries in asset_cfg.items():
        if kind.startswith("_"):
            continue
        for slot, entry in enumerate(entries):
            files = entry.get("files") or ([entry["file"]] if entry.get("file") else [])
            for part, rel in enumerate(files):
                path = os.path.join(DEFAULT_USER, rel)
                if not os.path.exists(path):
                    sys.exit(f"missing asset {path}")
                clo = mh_formats.load_mhclo(path)
                obj = mh_formats.load_obj(clo.obj_file)
                if len(obj.verts) != len(clo.refs):
                    sys.exit(f"{rel}: {len(obj.verts)} obj vertices vs {len(clo.refs)} fitting rows")
                assets.append({"kind": kind, "slot": slot, "part": part, "id": entry["id"], "gender": entry["gender"],
                               "file": rel, "clo": clo, "obj": obj})

    body_verts = model.base.group_verts["body"]
    keep_set = set(body_verts.tolist())
    for g, v in model.base.group_verts.items():
        if g.startswith("joint-"):
            keep_set.update(v.tolist())
    for b in model.rig.values():
        for end in (b["head"], b["tail"]):
            if end["strategy"] == "MEAN":
                keep_set.update(end["vertex_indices"])
    for a in assets:
        keep_set.update(np.unique(a["clo"].refs).tolist())
        for ax in a["clo"].scales.values():
            keep_set.update(ax[:2])
    keep = np.array(sorted(keep_set), dtype=np.int64)
    if len(keep) >= 65536:
        sys.exit("compact vertex count does not fit uint16")
    remap = -np.ones(len(model.base.verts), dtype=np.int64)
    remap[keep] = np.arange(len(keep))
    print(f"compact vertices: {len(keep)} of {len(model.base.verts)}; {len(assets)} asset meshes")

    arrays = {"keep": keep.astype(np.int32), "base": (model.base.verts[keep] * 0.1).astype(np.float32)}

    # --- targets -----------------------------------------------------------------------------
    slider_targets = sorted({t for e in catalogue for t in e["negative"] + e["positive"]})
    missing = [t for t in slider_targets if not model.has_target(t)]
    if missing:
        sys.exit(f"catalogue targets missing on disk: {missing[:8]}")
    face_units = face_unit_keys(model)
    keys = macro_target_keys(model) + slider_targets + face_units
    names, scales, starts, counts, dense_flags = [], [], [], [], []
    sparse_idx, deltas = [], []
    cursor_sparse, cursor_delta = 0, 0
    for key in keys:
        idx, delta = model.target(key)
        mask = (remap[idx] >= 0) & (np.abs(delta).max(1) > MOVE_EPS)
        cidx, cdelta = remap[idx[mask]], delta[mask] * 0.1  # metres
        peak = float(np.abs(cdelta).max()) if len(cdelta) else 0.0
        scale = peak / 32767.0 if peak > 0 else 1.0
        q = np.round(cdelta / scale).astype(np.int16)
        dense = len(cidx) > DENSE_FRACTION * len(keep)
        names.append(key)
        scales.append(scale)
        dense_flags.append(dense)
        if dense:
            block = np.zeros((len(keep), 3), dtype=np.int16)
            block[cidx] = q
            starts.append(cursor_delta)
            counts.append(len(keep))
            deltas.append(block.reshape(-1))
            cursor_delta += len(keep) * 3
        else:
            order = np.argsort(cidx)
            starts.append(cursor_delta)
            counts.append(len(cidx))
            sparse_idx.append(cidx[order].astype(np.uint16))
            deltas.append(q[order].reshape(-1))
            cursor_delta += len(cidx) * 3
    # sparse targets index their own run of sparse_idx: its start is (delta start / 3) minus the dense
    # vertices before it, so store it explicitly
    sparse_start, run = [], 0
    for dense, count in zip(dense_flags, counts):
        sparse_start.append(-1 if dense else run)
        run += 0 if dense else count
    arrays.update({
        "target_names": np.array(names), "target_scale": np.array(scales, dtype=np.float32),
        "target_delta_start": np.array(starts, dtype=np.int32), "target_count": np.array(counts, dtype=np.int32),
        "target_dense": np.array(dense_flags, dtype=np.uint8), "target_sparse_start": np.array(sparse_start, dtype=np.int32),
        "sparse_index": np.concatenate(sparse_idx) if sparse_idx else np.zeros(0, np.uint16),
        "delta": np.concatenate(deltas).astype(np.int16),
        "face_units": np.array(face_units),
        "beard_mask": np.round(beard_masks(model)[keep] * 255.0).astype(np.uint8),
        "macro_json": np.array(json.dumps(model.macro_config)),
        "catalogue_json": np.array(json.dumps(catalogue)),
        "assets_json": np.array(json.dumps({k: v for k, v in asset_cfg.items() if not k.startswith("_")})),
    })
    print(f"targets: {len(names)} ({sum(dense_flags)} dense), deltas {cursor_delta // 3}, "
          f"~{(arrays['delta'].nbytes + arrays['sparse_index'].nbytes) / 1e6:.1f} MB")

    # --- joints (game_engine rig) --------------------------------------------------------------
    bone_names = list(model.rig.keys())
    joint_ptr, joint_idx = [0], []
    for bone in bone_names:
        for end in ("head", "tail"):
            spec = model.rig[bone][end]
            src = model.base.group_verts[spec["cube_name"]] if spec["strategy"] == "CUBE" else np.array(spec["vertex_indices"])
            joint_idx.extend(remap[src].tolist())
            joint_ptr.append(len(joint_idx))
    arrays.update({
        "bone_names": np.array([profile.get(b, b) for b in bone_names]),
        "bone_parents": np.array([profile.get(model.rig[b]["parent"], model.rig[b]["parent"]) for b in bone_names]),
        "joint_ptr": np.array(joint_ptr, dtype=np.int32), "joint_index": np.array(joint_idx, dtype=np.int32),
    })

    # --- body skin weights (compact space, 4 bones) ------------------------------------------
    dense_w = np.zeros((len(keep), len(bone_names)))
    for bi, bone in enumerate(bone_names):
        for v, w in model.skin_weights["weights"].get(bone, []):
            if remap[v] >= 0:
                dense_w[remap[v], bi] = w
    unweighted = dense_w.sum(1) <= 0
    dense_w[unweighted, bone_names.index("Root") if "Root" in bone_names else 0] = 1.0
    body_bones, body_weights = top4(dense_w)

    # --- body render mesh --------------------------------------------------------------------
    body_faces = [f for f, g in zip(model.base.faces, model.base.face_group) if g == "body"]
    src, uv, index = render_mesh(triangulate(body_faces), model.base.uvs)
    csrc = remap[src]
    pos = model.base.verts[src] * 0.1
    nrm = vertex_normals(pos, index)
    arrays.update({
        "body_vertex": csrc.astype(np.int32), "body_uv": uv, "body_index": index,
        "body_tangent": tangents(pos, nrm, uv, index),
        "skin_bones": body_bones, "skin_weights": body_weights,
    })
    print(f"body: {len(src)} render vertices, {len(index) // 3} triangles")

    # --- assets ------------------------------------------------------------------------------
    meta = []
    for i, a in enumerate(assets):
        clo, obj = a["clo"], a["obj"]
        src, uv, index = render_mesh(triangulate(obj.faces), obj.uvs)
        refs = remap[clo.refs]
        if (refs < 0).any():
            sys.exit(f"{a['file']}: reference outside the compact vertices")
        # skin: barycentric blend of the referenced body vertices' weights
        w = (dense_w[refs] * clo.weights[:, :, None]).sum(1)
        bones, weights = top4(w)
        scale_pairs = np.full((3, 2), -1, dtype=np.int32)
        scale_ref = np.ones(3, dtype=np.float32)
        for axis, j in (("x", 0), ("y", 1), ("z", 2)):
            if axis in clo.scales:
                va, vb, ref = clo.scales[axis]
                scale_pairs[j] = (remap[va], remap[vb])
                scale_ref[j] = ref * 0.1
        fitted = HumanModel.fit(clo, model.base.verts)[src] * 0.1
        prefix = f"asset{i}_"
        arrays.update({
            prefix + "refs": refs.astype(np.int32), prefix + "weights": clo.weights.astype(np.float32),
            prefix + "offsets": (clo.offsets * 0.1).astype(np.float32), prefix + "scale_pairs": scale_pairs,
            prefix + "scale_ref": scale_ref, prefix + "vertex": src.astype(np.int32), prefix + "uv": uv,
            prefix + "index": index, prefix + "tangent": tangents(fitted, vertex_normals(fitted, index), uv, index),
            prefix + "bones": bones[src], prefix + "bone_weights": weights[src],
            prefix + "delete": remap[clo.delete_verts][remap[clo.delete_verts] >= 0].astype(np.int32),
        })
        meta.append({"kind": a["kind"], "slot": a["slot"], "part": a["part"], "id": a["id"], "gender": a["gender"],
                     "file": a["file"], "material": clo.material, "name": clo.name, "tags": clo.tags})
        print(f"asset {i:2d} {a['kind']:9s} {a['id']:16s} part {a['part']}: {len(src):5d} render verts, "
              f"{len(index) // 3:5d} tris, hides {len(arrays[prefix + 'delete'])}")
    arrays["asset_meta_json"] = np.array(json.dumps(meta))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    np.savez_compressed(out_path, **arrays)
    print(f"wrote {out_path}: {os.path.getsize(out_path) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
