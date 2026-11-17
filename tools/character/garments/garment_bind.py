"""Bind a garment to the game's body: what an exported garment holds, and how the game puts it back on.

Pure numpy (no scipy): the same file runs in the Blender add-on (tools/blender_scripts/addons/dyingstar_garments,
which ships a copy) and in the project's command-line tools.

A garment is modelled on the body in the bank's rest pose (the Vitruvian A pose), in the game's frame (metres,
Y up, facing +Z). Each garment vertex is bound to the closest point of the body's skin: the three corners of that
skin triangle (`refs`), the point's barycentric weights there (`weights`) and what is left (`offsets`). The game
puts it back on any body -- every shape, gender, age -- by the same sum (HumanMorph.fit_gd):

    position = sum(body[refs[k]] * weights[k]) + offsets * size

so a garment follows the skin it lies on. It is skinned by the bones of that skin (`bones`, `bone_weights`), and it
hides the skin it covers (`delete`: those body vertices' triangles are not drawn).

The arrays have the names, types and shapes of a worn asset in human_bank.npz (refit_outfits.py), so the game's
loaders read either.
"""
import hashlib
import json

import numpy as np

SKIN_ZONES = ("Face", "Torso", "Arms", "Legs")
HIDE_REACH = 0.06  # m: skin farther than this from the garment is never hidden by it
HIDE_COS = 0.5  # the garment must lie within 60 degrees of the skin's outward normal to hide it
HIDE_CLOSE = 3  # rings: gaps this wide in the hidden skin are filled (between toes)
TIGHT_BELOW = 0.05  # m: garment vertices closer than this to the skin are "on" it (clearance checks)
# Least clearance over the skin per GDD layer (0 underwear .. 5 heavy armour), m.
LAYER_CLEARANCE = (0.002, 0.004, 0.008, 0.015, 0.020, 0.030)
MAX_POKE_SHARE = 0.06  # a garment with more of its vertices inside the skin is refused
GARMENT_FORMAT = 1


class Body:
    """The skin a garment is bound to: positions (game frame), triangles, which vertices are skin, bone weights."""

    def __init__(self, points, tris, skin_mask, skin_bones, skin_weights, bone_count, signature=""):
        self.points = np.asarray(points, dtype=np.float64)
        self.tris = np.asarray(tris, dtype=np.int64).reshape(-1, 3)
        self.skin_mask = np.asarray(skin_mask, dtype=bool)
        self.skin_bones = np.asarray(skin_bones, dtype=np.int64)
        self.skin_weights = np.asarray(skin_weights, dtype=np.float64)
        self.bone_count = int(bone_count)
        self.signature = signature
        skin_tri = self.skin_mask[self.tris].all(1)
        self.skin_tris = self.tris[skin_tri]
        self.normals = vertex_normals(self.points, self.tris)

    @staticmethod
    def from_bank(bank, targets=None):
        """The body of a human_bank.npz (a dict of its arrays), shaped by {target name: weight}."""
        tris = bank_triangles(bank)
        mask = np.zeros(len(bank["base"]), dtype=bool)
        zones = [str(z) for z in bank["zone_names"]]
        for z, zone in enumerate(zones):
            if zone in SKIN_ZONES:
                mask[bank["body_vertex"][bank["zone_vertex_ptr"][z]:bank["zone_vertex_ptr"][z + 1]]] = True
        return Body(morph(bank, targets or {}), tris, mask, bank["skin_bones"], bank["skin_weights"],
                    len(bank["bone_names"]), body_signature(bank["base"], tris))


def bank_triangles(bank):
    """The body's triangles over its welded (compact) vertices, every zone, as the bank stores them."""
    index = bank["body_index"].astype(np.int64).copy()
    for z in range(len(bank["zone_names"])):
        index[bank["zone_index_ptr"][z]:bank["zone_index_ptr"][z + 1]] += bank["zone_vertex_ptr"][z]
    return bank["body_vertex"].astype(np.int64)[index].reshape(-1, 3)


def body_signature(base, tris):
    """A garment's refs only mean something on the body it was bound to: vertex count, positions and triangles."""
    h = hashlib.sha1()
    h.update(np.ascontiguousarray(base, dtype="<f4").tobytes())
    h.update(np.ascontiguousarray(tris, dtype="<i4").tobytes())
    return "v1-%d-%s" % (len(base), h.hexdigest()[:16])


def morph(bank, targets):
    """The bank's base body plus {target name: weight}, in doubles (HumanMorph.morph_gd)."""
    verts = bank["base"].astype(np.float64).copy()
    names = [str(t) for t in bank["target_names"]]
    for name, weight in targets.items():
        if weight == 0.0:
            continue
        t = names.index(name)
        start, moved, scale = bank["target_delta_start"][t], bank["target_count"][t], bank["target_scale"][t]
        d = bank["delta"][start:start + moved * 3].reshape(-1, 3).astype(np.float64) * scale * weight
        if bank["target_dense"][t]:
            verts += d
        else:
            s = bank["target_sparse_start"][t]
            verts[bank["sparse_index"][s:s + moved].astype(np.int64)] += d
    return verts


# --- geometry -------------------------------------------------------------------------------------------------

def vertex_normals(pos, tris):
    """Area-weighted vertex normals; triangles counter-clockwise seen from outside."""
    tri = np.asarray(tris).reshape(-1, 3)
    fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    out = np.zeros_like(pos, dtype=np.float64)
    for c in range(3):
        np.add.at(out, tri[:, c], fn)
    return out / np.maximum(np.linalg.norm(out, axis=1, keepdims=True), 1e-12)


def knn(points, targets, k):
    """The k nearest targets of each point: (distance, index), nearest first. Brute force in row blocks."""
    points = np.asarray(points, dtype=np.float64)
    targets = np.asarray(targets, dtype=np.float64)
    k = min(k, len(targets))
    rows = max(1, int(1.5e7 // max(len(targets), 1)))
    t2 = (targets * targets).sum(1)
    dist = np.empty((len(points), k))
    idx = np.empty((len(points), k), dtype=np.int64)
    for s in range(0, len(points), rows):
        p = points[s:s + rows]
        d2 = (p * p).sum(1)[:, None] - 2.0 * p @ targets.T + t2[None, :]
        part = np.argpartition(d2, k - 1, axis=1)[:, :k] if k < len(targets) else np.tile(np.arange(k), (len(p), 1))
        pd = np.take_along_axis(d2, part, axis=1)
        order = np.argsort(pd, axis=1)
        idx[s:s + rows] = np.take_along_axis(part, order, axis=1)
        dist[s:s + rows] = np.sqrt(np.maximum(np.take_along_axis(pd, order, axis=1), 0.0))
    return dist, idx


def closest_on_triangles(p, a, b, c):
    """Closest point to p on triangles (a, b, c), row by row: (point, barycentric weights). Ericson, 5.1.5."""
    ab, ac, ap = b - a, c - a, p - a
    d1, d2 = (ab * ap).sum(-1), (ac * ap).sum(-1)
    bp = p - b
    d3, d4 = (ab * bp).sum(-1), (ac * bp).sum(-1)
    cp = p - c
    d5, d6 = (ab * cp).sum(-1), (ac * cp).sum(-1)
    va, vb, vc = d3 * d6 - d5 * d4, d5 * d2 - d1 * d6, d1 * d4 - d3 * d2
    denom = va + vb + vc
    denom = np.where(np.abs(denom) < 1e-30, 1e-30, denom)
    v, w = vb / denom, vc / denom
    bary = np.stack([1.0 - v - w, v, w], -1)

    def put(cond, value):
        nonlocal bary
        bary = np.where(cond[..., None], value, bary)

    def safe(x):
        return np.where(np.abs(x) < 1e-30, 1e-30, x)

    zero = np.zeros_like(d1)
    # Ericson tests A, B, AB, C, AC, BC in that order, the first that holds wins: set them last to first.
    t = (d4 - d3) / safe((d4 - d3) + (d5 - d6))
    put((va <= 0) & (d4 - d3 >= 0) & (d5 - d6 >= 0), np.stack([zero, 1.0 - t, t], -1))
    t = d2 / safe(d2 - d6)
    put((vb <= 0) & (d2 >= 0) & (d6 <= 0), np.stack([1.0 - t, zero, t], -1))
    put((d6 >= 0) & (d5 <= d6), np.stack([zero, zero, zero + 1.0], -1))
    t = d1 / safe(d1 - d3)
    put((vc <= 0) & (d1 >= 0) & (d3 <= 0), np.stack([1.0 - t, t, zero], -1))
    put((d3 >= 0) & (d4 <= d3), np.stack([zero, zero + 1.0, zero], -1))
    put((d1 <= 0) & (d2 <= 0), np.stack([zero + 1.0, zero, zero], -1))
    q = a * bary[..., 0:1] + b * bary[..., 1:2] + c * bary[..., 2:3]
    return q, bary


def vertex_triangles(tris, count):
    """Per vertex, the triangles around it, padded with -1: (count, max valence)."""
    tris = np.asarray(tris).reshape(-1, 3)
    vert = tris.reshape(-1)
    tri = np.repeat(np.arange(len(tris)), 3)
    order = np.argsort(vert, kind="stable")
    vert, tri = vert[order], tri[order]
    counts = np.bincount(vert, minlength=count)
    width = max(int(counts.max()) if len(counts) else 1, 1)
    out = np.full((count, width), -1, dtype=np.int64)
    start = np.concatenate([[0], np.cumsum(counts)[:-1]])
    slot = np.arange(len(vert)) - start[vert]
    out[vert, slot] = tri
    return out


def closest_on_mesh(points, verts, tris, near=6, allowed=None):
    """Closest point of a triangle mesh to each point: (point, triangle index, barycentric weights, distance).
    Searched among the triangles around the `near` closest vertices; `allowed` (bool per vertex) keeps the others
    out (a triangle counts when its three vertices are allowed)."""
    points = np.asarray(points, dtype=np.float64)
    tris = np.asarray(tris, dtype=np.int64).reshape(-1, 3)
    if allowed is not None:
        tris = tris[np.asarray(allowed, dtype=bool)[tris].all(1)]
    used = np.unique(tris)
    _d, near_idx = knn(points, verts[used], near)
    around = vertex_triangles(tris, len(verts))[used[near_idx]].reshape(len(points), -1)  # (n, near*valence)
    best_q = np.zeros((len(points), 3))
    best_t = np.zeros(len(points), dtype=np.int64)
    best_b = np.zeros((len(points), 3))
    best_d = np.full(len(points), np.inf)
    for col in range(around.shape[1]):
        t = around[:, col]
        ok = t >= 0
        if not ok.any():
            continue
        tt = np.where(ok, t, 0)
        corner = tris[tt]
        q, bary = closest_on_triangles(points, verts[corner[:, 0]], verts[corner[:, 1]], verts[corner[:, 2]])
        d = np.linalg.norm(points - q, axis=1)
        better = ok & (d < best_d)
        best_q[better], best_t[better], best_b[better], best_d[better] = q[better], tt[better], bary[better], d[better]
    return best_q, tris[best_t], best_b, best_d


def render_mesh(corner_vertex, corner_uv):
    """One render vertex per (vertex, uv) pair: (source vertex, uv with V downwards as Godot reads it, index).
    corner_vertex / corner_uv are per triangle corner, three per triangle, counter-clockwise."""
    corner_vertex = np.asarray(corner_vertex, dtype=np.int64)
    corner_uv = np.asarray(corner_uv, dtype=np.float64)
    key = np.column_stack([corner_vertex.astype(np.float64), np.round(corner_uv, 7)])
    _u, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
    # number render vertices in the order their first corner appears (stable, readable output)
    order = np.argsort(first)
    rank = np.empty_like(order)
    rank[order] = np.arange(len(order))
    src = corner_vertex[first[order]]
    uv = corner_uv[first[order]].astype(np.float32)
    uv[:, 1] = 1.0 - uv[:, 1]  # Blender / OBJ V runs up, Godot's down
    return src, uv, rank[inverse.reshape(-1)].astype(np.int32)


def tangents(pos, normal, uv, index):
    """Per render vertex tangent (xyz + handedness) from the triangles' UV gradients (build_human_bank.tangents)."""
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
    tan -= normal * (tan * normal).sum(1, keepdims=True)
    tan /= np.maximum(np.linalg.norm(tan, axis=1, keepdims=True), 1e-12)
    hand = np.sign((np.cross(normal, tan) * bit).sum(1))
    hand[hand == 0] = 1.0
    return np.column_stack([tan, hand]).astype(np.float32)


def top4(dense):
    """(n, bones) -> the 4 strongest bones and their renormalised weights."""
    if dense.shape[1] < 4:
        dense = np.pad(dense, ((0, 0), (0, 4 - dense.shape[1])))
    order = np.argsort(-dense, axis=1)[:, :4]
    w = np.take_along_axis(dense, order, axis=1)
    s = w.sum(1, keepdims=True)
    w = np.where(s > 0, w / np.maximum(s, 1e-12), np.array([1.0, 0, 0, 0]))
    return order.astype(np.uint8), w.astype(np.float32)


def dilate(mask, tris, rings=1):
    """Add the neighbours of `mask` (one ring per pass)."""
    tri = np.asarray(tris).reshape(-1, 3)
    mask = mask.copy()
    for _ in range(rings):
        hit = mask[tri].any(1)
        mask[tri[hit].reshape(-1)] = True
    return mask


def erode(mask, tris, rings=1):
    """Keep the vertices of `mask` whose every neighbour is in it too (one ring per pass)."""
    tri = np.asarray(tris).reshape(-1, 3)
    mask = mask.copy()
    for _ in range(rings):
        bad = ~mask[tri].all(1)
        out = np.zeros(len(mask), dtype=bool)
        out[tri[bad].reshape(-1)] = True
        mask &= ~out
    return mask


# --- bind / fit ------------------------------------------------------------------------------------------------

def bind(points, tris, corner_uv, body, layer=1, allowed=None, scale_pairs=None, hide_reach=HIDE_REACH, hide=None):
    """Bind a garment on `body`.

    points: (n, 3) garment vertices, game frame, on body.points. tris: (m, 3) counter-clockwise. corner_uv: (m*3, 2)
    per corner (Blender's UV, V up), or None. allowed: bool per body vertex the garment may hang on (default: the
    skin). scale_pairs: (3, 2) body vertices whose distance scales the offsets per axis (a helmet grows with the
    head), or None. hide: the body vertices it hides, if chosen by hand (else found: the skin under it).

    Returns (arrays, report): the asset arrays (human_bank names and types) and the checks.
    """
    points = np.asarray(points, dtype=np.float64)
    tris = np.asarray(tris, dtype=np.int64).reshape(-1, 3)
    allowed = body.skin_mask if allowed is None else np.asarray(allowed, dtype=bool) & body.skin_mask
    q, corner, bary, dist = closest_on_mesh(points, body.points, body.tris, allowed=allowed)
    offsets = points - q
    pairs = np.full((3, 2), -1, dtype=np.int32) if scale_pairs is None else np.asarray(scale_pairs, dtype=np.int32)
    scale_ref = np.ones(3, dtype=np.float32)
    for axis in range(3):
        a, b = pairs[axis]
        if a >= 0 and b >= 0:
            scale_ref[axis] = abs(body.points[a, axis] - body.points[b, axis])
    # the offset is stored unscaled: fit multiplies it by (body size / scale_ref), 1 on the bound body
    normal = (body.normals[corner] * bary[..., None]).sum(1)
    normal /= np.maximum(np.linalg.norm(normal, axis=1, keepdims=True), 1e-12)
    clearance = (offsets * normal).sum(1)

    dense = np.zeros((len(points), body.bone_count))
    for k in range(3):
        for j in range(body.skin_bones.shape[1]):
            np.add.at(dense, (np.arange(len(points)), body.skin_bones[corner[:, k], j]),
                      bary[:, k] * body.skin_weights[corner[:, k], j])
    bones, bone_weights = top4(dense)

    if corner_uv is None:
        corner_uv = np.zeros((len(tris) * 3, 2))
    src, uv, index = render_mesh(tris.reshape(-1), corner_uv)
    normals = vertex_normals(points, tris)
    tangent = tangents(points[src], normals[src], uv, index)

    if hide is None:
        hide = hidden_skin(body, points, tris, hide_reach)
    report = check(points, tris, clearance, dist, layer, hide)
    arrays = {
        "refs": corner.astype(np.int32), "weights": bary.astype(np.float32), "offsets": offsets.astype(np.float32),
        "scale_pairs": pairs, "scale_ref": scale_ref,
        "vertex": src.astype(np.int32), "uv": uv, "index": index, "tangent": tangent,
        "bones": bones[src], "bone_weights": bone_weights[src], "delete": np.nonzero(hide)[0].astype(np.int32),
    }
    return arrays, report


def hidden_skin(body, points, tris, reach=HIDE_REACH):
    """The skin a garment covers: skin vertices with the garment within `reach` along their outward normal.
    The gaps are closed (between toes the normals point at the next toe, not at the shoe), then the whole is
    shrunk by one ring so the skin goes on under a hem (a body triangle is dropped as soon as one corner is).
    On the MakeHuman outfits this finds 89-100 % of what MakeHuman's own hide groups hid."""
    skin = np.nonzero(body.skin_mask)[0]
    q, _c, _b, dist = closest_on_mesh(body.points[skin], points, tris)
    out = q - body.points[skin]
    along = (out * body.normals[skin]).sum(1) / np.maximum(dist, 1e-12)
    covered = np.zeros(len(body.points), dtype=bool)
    covered[skin] = (dist < reach) & (along > HIDE_COS)
    closed = dilate(covered, body.skin_tris, HIDE_CLOSE) & body.skin_mask
    return erode(closed, body.skin_tris, HIDE_CLOSE + 1)


def check(points, tris, clearance, dist, layer, hide):
    """What the add-on shows: share of the garment inside the skin, share too close for its layer."""
    tight = dist < TIGHT_BELOW
    want = LAYER_CLEARANCE[max(0, min(int(layer), len(LAYER_CLEARANCE) - 1))]
    return {
        "vertices": int(len(points)), "triangles": int(len(tris)),
        "poke_share": float((clearance < 0.0).mean()) if len(points) else 0.0,
        "poke": np.nonzero(clearance < 0.0)[0],
        "close_share": float((tight & (clearance < want)).mean()) if len(points) else 0.0,
        "close": np.nonzero(tight & (clearance >= 0.0) & (clearance < want))[0],
        "clearance_wanted": want, "hidden_skin": int(np.count_nonzero(hide)),
        "ok": bool(len(points) == 0 or (clearance < 0.0).mean() <= MAX_POKE_SHARE),
    }


def fit(body_points, arrays):
    """The garment's vertices on a body (HumanMorph.fit_gd)."""
    body_points = np.asarray(body_points, dtype=np.float64)
    size = np.ones(3)
    for axis in range(3):
        a, b = arrays["scale_pairs"][axis]
        if a >= 0 and b >= 0:
            size[axis] = abs(body_points[a, axis] - body_points[b, axis]) / arrays["scale_ref"][axis]
    refs = arrays["refs"].astype(np.int64)
    w = arrays["weights"].astype(np.float64)
    return (body_points[refs] * w[..., None]).sum(1) + arrays["offsets"].astype(np.float64) * size


# --- the garment file ----------------------------------------------------------------------------------------------

META_KEYS = ("id", "zones", "support", "layer", "access", "hides", "material", "gender", "binding",
             "name_en", "name_fr", "bound_on", "body_signature")
ARRAY_KEYS = ("refs", "weights", "offsets", "scale_pairs", "scale_ref", "vertex", "uv", "index", "tangent",
              "bones", "bone_weights", "delete")


def write_garment(path, arrays, meta):
    """A .dsgarment: an npz of the asset arrays plus `meta_json` (meta.json of the plan)."""
    missing = [k for k in ARRAY_KEYS if k not in arrays]
    if missing:
        raise ValueError("garment arrays missing: %s" % ", ".join(missing))
    meta = dict(meta)
    meta["format"] = GARMENT_FORMAT
    out = {k: arrays[k] for k in ARRAY_KEYS}
    out["meta_json"] = np.array(json.dumps(meta, sort_keys=True))
    with open(path, "wb") as f:  # np.savez_compressed adds ".npz" to a bare path; a file object keeps the name
        np.savez_compressed(f, **out)


def read_garment(path):
    data = np.load(path, allow_pickle=False)
    meta = json.loads(str(data["meta_json"]))
    return {k: data[k] for k in ARRAY_KEYS}, meta
