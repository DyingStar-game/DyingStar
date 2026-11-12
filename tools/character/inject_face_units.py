"""Inject the 52 ARKit face units (and teeth + tongue) into an existing character .glb, nothing re-exported.

The reference (.npz from build_reference.py) is the same MPFB human rebuilt in Blender. Its body
and eyebrow proxies share the glb meshes' UV layout, so each glb vertex finds its reference vertex
by UV, exactly; a similarity fit on the face then carries the reference frame (Blender, Z up,
basemesh units) into the glb mesh frame. Teeth and tongue are new meshes, skinned 100% to the head
joint, their lower half driven by the shape keys (jawOpen moves them).

Every existing byte of the glb is kept: new data is appended to the binary chunk, morph targets are
added to the existing primitives as SPARSE accessors (only the vertices a face unit moves).
usage: inject_face_units.py in.glb reference.npz teeth.png tongue.png out.glb

in.glb must be the character WITHOUT face units (for man_ddurieux: the version before they were added,
`git show <commit>^:assets/_universe/characters/humanoids/man_ddurieux.glb`); the script refuses a glb
that already has them. teeth.png / tongue.png come from MPFB's data (teeth/teeth_base/teeth.png,
tongue/tongue01/tongue01_diffuse.png).
"""
import json
import struct
import sys

import numpy as np
from scipy.spatial import cKDTree

SRC, REF, TEETH_PNG, TONGUE_PNG, OUT = sys.argv[1:6]
MOVE_EPS = 1e-6  # m: a vertex a face unit moves less than this gets no sparse entry
UV_TOL = 2e-4  # a UV match farther than this is reported

with open(SRC, "rb") as f:
    blob = f.read()
json_len = struct.unpack_from("<I", blob, 12)[0]
gltf = json.loads(blob[20:20 + json_len])
bin_start = 20 + json_len + 8
bin_len = struct.unpack_from("<I", blob, 20 + json_len)[0]
binary = bytearray(blob[bin_start:bin_start + bin_len])
ref = np.load(REF, allow_pickle=False)
names = [str(n) for n in ref["names"]]
if any("targets" in p for m in gltf["meshes"] for p in m["primitives"]):
    sys.exit(f"{SRC} already has morph targets: start from the glb without face units")

COMPONENT = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}
WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_accessor(index):
    acc = gltf["accessors"][index]
    view = gltf["bufferViews"][acc["bufferView"]]
    dtype = COMPONENT[acc["componentType"]]
    width = WIDTH[acc["type"]]
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = view.get("byteStride", width * np.dtype(dtype).itemsize)
    raw = np.frombuffer(binary, dtype=np.uint8, count=stride * (acc["count"] - 1) + width * np.dtype(dtype).itemsize,
                        offset=start)
    out = np.empty((acc["count"], width), dtype=dtype)
    for i in range(width):
        out[:, i] = np.ndarray((acc["count"],), dtype=dtype, buffer=raw, offset=i * np.dtype(dtype).itemsize,
                               strides=(stride,))
    return out


def append(data, target=None):
    """Append bytes to the binary chunk (4-byte aligned) as a new bufferView; return its index."""
    while len(binary) % 4:
        binary.append(0)
    view = {"buffer": 0, "byteOffset": len(binary), "byteLength": len(data)}
    if target:
        view["target"] = target
    binary.extend(data)
    gltf["bufferViews"].append(view)
    return len(gltf["bufferViews"]) - 1


def add_accessor(array, component, kind, minmax=False, target=None):
    array = np.ascontiguousarray(array)
    acc = {"bufferView": append(array.tobytes(), target), "componentType": component, "count": len(array), "type": kind}
    if minmax:
        acc["min"] = array.min(axis=0).astype(float).tolist()
        acc["max"] = array.max(axis=0).astype(float).tolist()
    gltf["accessors"].append(acc)
    return len(gltf["accessors"]) - 1


def add_sparse_target(count, deltas):
    """A POSITION morph target: zeros everywhere but the vertices this unit moves."""
    moved = np.nonzero(np.abs(deltas).max(axis=1) > MOVE_EPS)[0].astype(np.uint32)
    values = deltas[moved].astype(np.float32)
    acc = {"componentType": 5126, "count": count, "type": "VEC3",
           "min": (values.min(axis=0) if len(moved) else np.zeros(3)).astype(float).tolist(),
           "max": (values.max(axis=0) if len(moved) else np.zeros(3)).astype(float).tolist()}
    if len(moved):
        acc["sparse"] = {"count": int(len(moved)),
                         "indices": {"bufferView": append(moved.tobytes()), "componentType": 5125},
                         "values": {"bufferView": append(values.tobytes())}}
    gltf["accessors"].append(acc)
    return len(gltf["accessors"]) - 1


def reference_uv_tree(key):
    """Per-corner UVs of the reference mesh (Blender convention), so seam vertices match every side."""
    tris, tri_uv = ref[f"{key}_tris"], ref[f"{key}_tri_uv"]
    return cKDTree(tri_uv.reshape(-1, 2)), tris.reshape(-1)


def match_by_uv(mesh_index, key):
    prim = gltf["meshes"][mesh_index]["primitives"][0]
    uv = read_accessor(prim["attributes"]["TEXCOORD_0"]).astype(np.float64)
    uv[:, 1] = 1.0 - uv[:, 1]  # glTF V runs down, Blender's up
    tree, corner_vertex = reference_uv_tree(key)
    dist, corner = tree.query(uv)
    far = int((dist > UV_TOL).sum())
    print(f"  {gltf['meshes'][mesh_index]['name']}: {len(uv)} vertices, UV match max {dist.max():.2e}, {far} beyond tolerance")
    return corner_vertex[corner], prim


def similarity(src, dst):
    """Scale, rotation, translation taking src points onto dst (Umeyama)."""
    mu_s, mu_d = src.mean(0), dst.mean(0)
    a, b = src - mu_s, dst - mu_d
    u, sig, vt = np.linalg.svd(b.T @ a / len(src))
    d = np.eye(3)
    d[2, 2] = np.sign(np.linalg.det(u @ vt))
    rot = u @ d @ vt
    scale = np.trace(np.diag(sig) @ d) / (a ** 2).sum(1).mean()
    return scale, rot, mu_d - scale * rot @ mu_s


def mesh_index(name):
    return next(i for i, m in enumerate(gltf["meshes"]) if m["name"].startswith(name))


# --- body: match, fit the frame on the face, inject ------------------------------------------
body = mesh_index("male_muscle_13290")
print("body")
body_ref_idx, body_prim = match_by_uv(body, "body")
body_pos = read_accessor(body_prim["attributes"]["POSITION"]).astype(np.float64)
ref_deltas = ref["body_deltas"]  # (52, n_ref, 3)
face = np.abs(ref_deltas).max(axis=(0, 2))[body_ref_idx] > MOVE_EPS
scale, rot, shift = similarity(ref["body_rest"][body_ref_idx[face]], body_pos[face])
fit = scale * (ref["body_rest"][body_ref_idx[face]] @ rot.T) + shift
print(f"  face fit on {face.sum()} vertices: scale {scale:.4f}, residual rms {np.sqrt(((fit - body_pos[face]) ** 2).sum(1).mean()) * 1000:.2f} mm, max {np.sqrt(((fit - body_pos[face]) ** 2).sum(1)).max() * 1000:.2f} mm")


def to_glb(delta):
    return scale * (delta @ rot.T)


def inject_targets(mesh_idx, prim, ref_idx, key):
    deltas = ref[f"{key}_deltas"]
    count = len(ref_idx)
    prim["targets"] = [{"POSITION": add_sparse_target(count, to_glb(deltas[k][ref_idx]))} for k in range(len(names))]
    mesh = gltf["meshes"][mesh_idx]
    mesh["weights"] = [0.0] * len(names)
    mesh.setdefault("extras", {})["targetNames"] = names


inject_targets(body, body_prim, body_ref_idx, "body")
print("eyebrows")
brow = mesh_index("eyebrow004")
brow_ref_idx, brow_prim = match_by_uv(brow, "eyebrows")
inject_targets(brow, brow_prim, brow_ref_idx, "eyebrows")

# --- teeth and tongue: new meshes, skinned to the head ---------------------------------------
skin_node = next(n for n in gltf["nodes"] if n.get("mesh") == body)
head_joint = next(k for k, j in enumerate(gltf["skins"][skin_node["skin"]]["joints"]) if gltf["nodes"][j]["name"] in ("head", "Head"))
skin_material = gltf["materials"][body_prim["material"]]


def add_image_material(png_path, name, roughness):
    with open(png_path, "rb") as f:
        gltf.setdefault("images", []).append({"name": name, "mimeType": "image/png", "bufferView": append(f.read())})
    gltf.setdefault("textures", []).append({"source": len(gltf["images"]) - 1, "sampler": 0} if gltf.get("samplers") else {"source": len(gltf["images"]) - 1})
    gltf["materials"].append({"name": name, "pbrMetallicRoughness": {
        "baseColorTexture": {"index": len(gltf["textures"]) - 1}, "metallicFactor": 0.0, "roughnessFactor": roughness}})
    return len(gltf["materials"]) - 1


def add_bodypart(key, png, roughness):
    rest, tris, tri_uv, deltas = ref[f"{key}_rest"], ref[f"{key}_tris"], ref[f"{key}_tri_uv"], ref[f"{key}_deltas"]
    # glTF needs one vertex per (position, uv) pair.
    corners = np.column_stack([tris.reshape(-1), np.round(tri_uv.reshape(-1, 2), 6)])
    unique, inverse = np.unique(corners, axis=0, return_inverse=True)
    src_vertex = unique[:, 0].astype(np.int64)
    uv = unique[:, 1:3].copy()
    uv[:, 1] = 1.0 - uv[:, 1]
    pos = scale * (rest[src_vertex] @ rot.T) + shift
    faces = inverse.reshape(-1, 3)
    normals = np.zeros_like(pos)
    tri_n = np.cross(pos[faces[:, 1]] - pos[faces[:, 0]], pos[faces[:, 2]] - pos[faces[:, 0]])
    for c in range(3):
        np.add.at(normals, faces[:, c], tri_n)
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
    n = len(pos)
    attributes = {
        "POSITION": add_accessor(pos.astype(np.float32), 5126, "VEC3", minmax=True, target=34962),
        "NORMAL": add_accessor(normals.astype(np.float32), 5126, "VEC3", target=34962),
        "TEXCOORD_0": add_accessor(uv.astype(np.float32), 5126, "VEC2", target=34962),
        "JOINTS_0": add_accessor(np.tile(np.array([head_joint, 0, 0, 0], np.uint8), (n, 1)), 5121, "VEC4", target=34962),
        "WEIGHTS_0": add_accessor(np.tile(np.array([1, 0, 0, 0], np.float32), (n, 1)), 5126, "VEC4", target=34962),
    }
    index_type = (5123, np.uint16) if n < 65536 else (5125, np.uint32)
    prim = {"attributes": attributes, "indices": add_accessor(faces.reshape(-1).astype(index_type[1]), index_type[0], "SCALAR", target=34963),
            "material": add_image_material(png, key, roughness),
            "targets": [{"POSITION": add_sparse_target(n, to_glb(deltas[k][src_vertex]))} for k in range(len(names))]}
    gltf["meshes"].append({"name": f"{key}.001", "primitives": [prim], "weights": [0.0] * len(names), "extras": {"targetNames": names}})
    node = {"name": f"test1.{key}", "mesh": len(gltf["meshes"]) - 1, "skin": skin_node["skin"]}
    for attr in ("translation", "rotation", "scale"):
        if attr in skin_node:
            node[attr] = skin_node[attr]
    gltf["nodes"].append(node)
    parent = next(nd for nd in gltf["nodes"] if gltf["nodes"].index(skin_node) in nd.get("children", []))
    parent["children"].append(len(gltf["nodes"]) - 1)
    print(f"{key}: {n} vertices, {len(faces)} triangles, head joint {head_joint}")


add_bodypart("teeth", TEETH_PNG, 0.35)
add_bodypart("tongue", TONGUE_PNG, 0.5)

# --- write -------------------------------------------------------------------------------------
while len(binary) % 4:
    binary.append(0)
gltf["buffers"][0]["byteLength"] = len(binary)
text = json.dumps(gltf, separators=(",", ":")).encode()
text += b" " * (-len(text) % 4)
total = 12 + 8 + len(text) + 8 + len(binary)
with open(OUT, "wb") as f:
    f.write(struct.pack("<III", 0x46546C67, 2, total))
    f.write(struct.pack("<II", len(text), 0x4E4F534A) + text)
    f.write(struct.pack("<II", len(binary), 0x004E4942) + bytes(binary))
print(f"wrote {OUT}: {total / 1e6:.1f} MB (was {len(blob) / 1e6:.1f} MB)")
