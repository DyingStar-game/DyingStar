"""Readers for the MakeHuman / MPFB data files the character pipeline consumes.

Everything stays in MakeHuman's own frame: Y up, the character facing +Z, its left on +X, decimetres.
That frame times 0.1 is already glTF / Godot's (metres, Y up), so no axis swap is ever needed here --
unlike MPFB, which converts to Blender's Z-up frame on load.

Formats (all plain text, CC0 data from MakeHuman / MPFB):
  base.obj        the basemesh: 19158 vertices, quads, one UV set; `g <name>` groups (body, helper-*,
                  joint-* cubes) tag the faces that follow.
  *.target(.gz)   "index dx dy dz" lines: a sparse vertex displacement.
  *.mhclo/.proxy  an asset fitted on the basemesh: per vertex 1 or 3 basemesh references, barycentric
                  weights and an offset scaled by x/y/z_scale; delete_verts ranges hide the body under it.
  rig.*.json      bones whose head/tail are the mean of a joint-* cube (CUBE) or of listed vertices (MEAN).
  weights.*.json  per bone, [basemesh vertex, weight] pairs.
"""
import gzip
import json
import os
from dataclasses import dataclass, field

import numpy as np


@dataclass
class ObjMesh:
    verts: np.ndarray  # (n, 3) float64, decimetres
    uvs: np.ndarray  # (m, 2) float64
    faces: list  # per face: (vertex indices tuple, uv indices tuple)
    face_group: list  # per face: group name
    group_verts: dict = field(default_factory=dict)  # group -> sorted np.ndarray of vertex indices


def load_obj(path: str) -> ObjMesh:
    verts, uvs, faces, face_group = [], [], [], []
    group = ""
    group_sets: dict = {}
    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                verts.append([float(x) for x in line.split()[1:4]])
            elif line.startswith("vt "):
                uvs.append([float(x) for x in line.split()[1:3]])
            elif line.startswith("g "):
                group = line.split(maxsplit=1)[1].strip()
            elif line.startswith("f "):
                vi, ti = [], []
                for corner in line.split()[1:]:
                    parts = corner.split("/")
                    vi.append(int(parts[0]) - 1)
                    ti.append(int(parts[1]) - 1 if len(parts) > 1 and parts[1] else -1)
                faces.append((tuple(vi), tuple(ti)))
                face_group.append(group)
                group_sets.setdefault(group, set()).update(vi)
    mesh = ObjMesh(np.array(verts, dtype=np.float64), np.array(uvs, dtype=np.float64), faces, face_group)
    mesh.group_verts = {g: np.array(sorted(s), dtype=np.int64) for g, s in group_sets.items()}
    return mesh


def load_target(path: str):
    """(indices int64 (k,), deltas float64 (k, 3)) of a .target or .target.gz file."""
    opener = gzip.open if path.endswith(".gz") else open
    idx, delta = [], []
    with opener(path, "rt") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            idx.append(int(parts[0]))
            delta.append([float(parts[1]), float(parts[2]), float(parts[3])])
    return np.array(idx, dtype=np.int64), np.array(delta, dtype=np.float64).reshape(-1, 3)


@dataclass
class Mhclo:
    name: str
    obj_file: str
    refs: np.ndarray  # (n, 3) int64 basemesh vertices
    weights: np.ndarray  # (n, 3) float64
    offsets: np.ndarray  # (n, 3) float64, MakeHuman axes, scaled by the x/y/z sizes
    scales: dict  # axis ("x","y","z") -> (vertex a, vertex b, reference length)
    delete_verts: np.ndarray  # basemesh vertices hidden under the asset
    tags: list
    material: str
    weights_file: str


def load_mhclo(path: str) -> Mhclo:
    folder = os.path.dirname(path)
    refs, weights, offsets, delete, tags = [], [], [], [], []
    scales, name, obj_file, material, weights_file = {}, "", "", "", ""
    status = ""
    previous = None  # last delete_verts index: a "-" range may straddle two lines
    pending_range = False
    with open(path) as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            words = line.split()
            # Some assets put keywords (material, vertexboneweights_file) between "verts 0" and the vertex
            # lines: a keyword line is handled below without leaving the vertex block.
            if status == "v" and words[0].isdigit():
                if len(words) == 1:
                    v = int(words[0])
                    refs.append([v, v, v])
                    weights.append([1.0, 0.0, 0.0])
                    offsets.append([0.0, 0.0, 0.0])
                    continue
                else:
                    refs.append([int(w) for w in words[0:3]])
                    weights.append([float(w) for w in words[3:6]])
                    offsets.append([float(w) for w in words[6:9]])
                    continue
            if status == "d":
                if not words[0].isdigit() and words[0] != "-":
                    status = ""
                else:
                    for w in words:
                        if w == "-":
                            pending_range = True
                            continue
                        v = int(w)
                        if pending_range and previous is not None:
                            delete.extend(range(previous + 1, v + 1))
                        else:
                            delete.append(v)
                        pending_range = False
                        previous = v
                    continue
            key = words[0]
            if key == "verts":
                status = "v"
            elif key == "delete_verts":
                status = "d"
            elif key in ("x_scale", "y_scale", "z_scale"):
                scales[key[0]] = (int(words[1]), int(words[2]), float(words[3]))
            elif key == "name":
                name = words[1]
            elif key == "obj_file":
                obj_file = os.path.join(folder, words[1])
            elif key == "material":
                material = os.path.join(folder, words[1])
            elif key == "tag":
                tags.append(" ".join(words[1:]).lower())
            elif key.startswith("vertexboneweights"):
                weights_file = os.path.join(folder, words[1])
    return Mhclo(name, obj_file, np.array(refs, dtype=np.int64), np.array(weights, dtype=np.float64),
                 np.array(offsets, dtype=np.float64), scales, np.array(sorted(set(delete)), dtype=np.int64),
                 tags, material, weights_file)


def load_json(path: str):
    with open(path) as f:
        return json.load(f)


def parse_mhm(path: str) -> dict:
    """The parts of a MakeHuman .mhm the pipeline needs: macros, race, modifier targets and assets."""
    macro_keys = {"Gender": "gender", "Age": "age", "Muscle": "muscle", "Weight": "weight", "Height": "height",
                  "BodyProportions": "proportions", "BreastSize": "cupsize", "BreastFirmness": "firmness"}
    info = {"macros": {}, "race": {}, "modifiers": [], "assets": {}, "skin": "", "eyes_material": ""}
    with open(path) as f:
        for line in f:
            words = line.split()
            if not words:
                continue
            if words[0] == "modifier":
                name, value = words[1], float(words[2])
                leaf = name.split("/")[-1]
                if leaf in macro_keys:
                    info["macros"][macro_keys[leaf]] = value
                elif leaf in ("African", "Asian", "Caucasian"):
                    info["race"][leaf.lower()] = value
                else:
                    info["modifiers"].append((name, value))
            elif words[0] in ("proxy", "hair", "eyebrows", "eyelashes", "eyes", "teeth", "tongue"):
                info["assets"][words[0]] = words[1]
            elif words[0] == "clothes":
                info["assets"].setdefault("clothes", []).append(words[1])
            elif words[0] == "skinMaterial":
                info["skin"] = words[1]
    return info


def modifier_to_target(name: str, value: float):
    """An mhm modifier line ("torso/torso-trans-down|up 0.128") -> (target leaf name, weight), or None.

    A bipolar modifier "<group>/<base>-<neg>|<pos>" picks the <pos> target for a positive value and the
    <neg> target for a negative one, with weight |value|; a unipolar one is its own target."""
    leaf = name.split("/", 1)[-1]
    if "|" in leaf:
        head, pos = leaf.rsplit("|", 1)
        base, neg = head.rsplit("-", 1)
        if abs(value) < 1e-9:
            return None
        return (f"{base}-{pos}" if value > 0 else f"{base}-{neg}"), abs(value)
    return leaf, value
