"""Re-fit MakeHuman's outfits on the Vitruvian body, and add them to the bank.

The outfits (CC0, MakeHuman / MPFB) are modelled on MakeHuman's basemesh; the game's body is now the
Vitruvian one -- another mesh, in another rest pose. Per outfit piece:

  1. the MakeHuman body it suits (a man's or a woman's) wears it, by MakeHuman's own rule (MHCLO);
  2. the Vitruvian body of the same gender is put in MakeHuman's pose (the T pose of the game skeleton),
     exactly as the game does it: each bone turned from its direction to the template's;
  3. the garment follows the bones from one body to the other: each bone stretches it along itself by
     the two bodies' bone lengths and across by their girths, blended by the garment's skin weights;
  4. what still cuts into the new body is pushed back out to the clearance it had over the old one, and
     the correction is smoothed over the garment;
  5. the result is taken back to the Vitruvian rest pose and bound to the new body the way the bank
     binds every worn mesh: three body vertices, their weights, and an offset.

The body vertices an outfit hides are the ones lying where MakeHuman hid its own. A piece that still
cuts into the body by more than MAX_POKE_SHARE of its vertices is left out, and reported.

usage: python3 refit_outfits.py human_bank.npz <project root> [--import man_ddurieux.glb.import]
"""
import json
import os
import re
import sys

import numpy as np
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "human_bank"))
import mh_formats  # noqa: E402
from build_human_bank import bone_profile_map, render_mesh, tangents, top4, triangulate, vertex_normals  # noqa: E402
from human_model import DEFAULT_USER, HumanModel  # noqa: E402

TEXTURES_REL = "assets/_universe/characters/human/textures"
MIN_CLEARANCE = 0.004  # m: a garment never sits closer to the skin than this
TIGHT_BELOW = 0.05  # m: a garment vertex farther than this from the old body is loose (a hem): left alone
MAX_POKE_SHARE = 0.06
SMOOTH_PASSES = 6
OUTFITS = [  # id, gender, MakeHuman pieces (suit, shoes)
    ("male_casual01", "male", ["clothes/male_casualsuit01/male_casualsuit01.mhclo", "clothes/shoes03/shoes03.mhclo"]),
    ("male_casual02", "male", ["clothes/male_casualsuit02/male_casualsuit02.mhclo", "clothes/shoes01/shoes01.mhclo"]),
    ("male_casual04", "male", ["clothes/male_casualsuit04/male_casualsuit04.mhclo", "clothes/shoes04/shoes04.mhclo"]),
    ("male_work01", "male", ["clothes/male_worksuit01/male_worksuit01.mhclo", "clothes/shoes03/shoes03.mhclo"]),
    ("female_casual01", "female", ["clothes/female_casualsuit01/female_casualsuit01.mhclo", "clothes/shoes04/shoes04.mhclo"]),
    ("female_casual02", "female", ["clothes/female_casualsuit02/female_casualsuit02.mhclo", "clothes/shoes01/shoes01.mhclo"]),
]
# Left out: female_sportsuit01 -- its cropped top ends above the bust line of the Vitruvian woman.


class Body:
    """A body with the game skeleton: vertices, joints, per-vertex bone weights, and its T-pose carry."""

    def __init__(self, verts, joints, dense_w, parents, aims, template_dirs=None):
        self.verts, self.joints, self.w, self.parents, self.aims = verts, joints, dense_w, parents, aims
        count = len(joints)
        self.turn = [np.eye(3)] * count
        self.rest = joints.copy()
        for b in range(count):
            p = parents[b]
            self.turn[b] = self.turn[p] if p >= 0 else np.eye(3)
            if template_dirs is not None and aims[b] >= 0:
                self.turn[b] = shortest_arc(unit(joints[aims[b]] - joints[b]), template_dirs[b])
            self.rest[b] = self.rest[p] + self.turn[p] @ (joints[b] - joints[p]) if p >= 0 else joints[b]

    def carry(self, points, weights):
        """Skin points (their dense bone weights given) from the body's own pose to the T pose."""
        out = np.zeros_like(points)
        for b in range(len(self.joints)):
            wb = weights[:, b:b + 1]
            if wb.max() > 0:
                out += wb * (self.rest[b] + (points - self.joints[b]) @ self.turn[b].T)
        return out

    def uncarry(self, points, weights):
        """The inverse of carry, per point (the blended transform inverted)."""
        m = np.zeros((len(points), 3, 3))
        t = np.zeros((len(points), 3))
        for b in range(len(self.joints)):
            wb = weights[:, b]
            if wb.max() > 0:
                m += wb[:, None, None] * self.turn[b]
                t += wb[:, None] * (self.rest[b] - self.turn[b] @ self.joints[b])
        return np.einsum("nij,nj->ni", np.linalg.inv(m), points - t)


def unit(v):
    return v / max(np.linalg.norm(v), 1e-12)


def shortest_arc(a, b):
    v, c = np.cross(a, b), float(a @ b)
    if c < -0.999999:
        return -np.eye(3)
    k = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + k + k @ k / (1.0 + c)


def bone_frames(body_t, verts_t, weights, aims, parents):
    """Per bone, in the T pose: joint, direction (its own or its parent's), length, girth."""
    count = len(body_t.rest)
    direction, length, girth = [None] * count, np.ones(count), np.ones(count)
    for b in range(count):
        if aims[b] >= 0:
            d = body_t.rest[aims[b]] - body_t.rest[b]
            direction[b], length[b] = unit(d), np.linalg.norm(d)
        else:
            direction[b] = direction[parents[b]] if parents[b] >= 0 and direction[parents[b]] is not None else np.array([0.0, 1.0, 0.0])
            length[b] = length[parents[b]] if parents[b] >= 0 else 1.0
        mine = weights[:, b] > 0.5
        if mine.sum() >= 8:
            rel = verts_t[mine] - body_t.rest[b]
            radial = rel - np.outer(rel @ direction[b], direction[b])
            girth[b] = np.median(np.linalg.norm(radial, axis=1))
        else:
            girth[b] = girth[parents[b]] if parents[b] >= 0 else 1.0
    return direction, length, girth


def laplacian_smooth(values, index, passes):
    tri = index.reshape(-1, 3)
    for _ in range(passes):
        acc = np.zeros_like(values)
        cnt = np.zeros(len(values))
        for a, b in ((0, 1), (1, 2), (2, 0)):
            np.add.at(acc, tri[:, a], values[tri[:, b]])
            np.add.at(acc, tri[:, b], values[tri[:, a]])
            np.add.at(cnt, tri[:, a], 1)
            np.add.at(cnt, tri[:, b], 1)
        values = 0.5 * values + 0.5 * acc / np.maximum(cnt, 1)[:, None]
    return values


def main():
    bank_path, root = sys.argv[1], sys.argv[2]
    import_path = sys.argv[sys.argv.index("--import") + 1] if "--import" in sys.argv else ""
    bank = dict(np.load(bank_path, allow_pickle=False))
    names = [str(b) for b in bank["bone_names"]]
    parents = [names.index(str(p)) if str(p) in names else -1 for p in bank["bone_parents"]]
    aims = bank["bone_aim"].tolist()
    count = len(names)
    target_names = [str(t) for t in bank["target_names"]]

    def vitruvian(gender_key):
        verts = bank["base"].astype(np.float64).copy()
        t = target_names.index(gender_key)
        start, n_moved, scale = bank["target_delta_start"][t], bank["target_count"][t], bank["target_scale"][t]
        d = bank["delta"][start:start + n_moved * 3].reshape(-1, 3).astype(np.float64) * scale
        if bank["target_dense"][t]:
            verts += d
        else:
            s = bank["target_sparse_start"][t]
            verts[bank["sparse_index"][s:s + n_moved].astype(np.int64)] += d
        return verts

    ptr, jidx, jw = bank["joint_ptr"], bank["joint_index"], bank["joint_weight"]
    vit_w = np.zeros((len(bank["base"]), count))
    np.put_along_axis(vit_w, bank["skin_bones"].astype(np.int64), bank["skin_weights"].astype(np.float64), axis=1)
    vit_tris = None

    model = HumanModel()
    profile = bone_profile_map(import_path)
    mh_w_all = np.zeros((len(model.base.verts), count))
    for bone, pairs in model.skin_weights["weights"].items():
        game = profile.get(bone, bone)
        if game in names:
            for v, w in pairs:
                mh_w_all[v, names.index(game)] = w
    loose = mh_w_all.sum(1) <= 0
    mh_w_all[loose, names.index("Root")] = 1.0
    mh_w_all /= mh_w_all.sum(1, keepdims=True)
    mh_body = model.base.group_verts["body"]

    # the Vitruvian body's welded triangles (compact vertices), for normals
    index = bank["body_index"].copy()
    for z in range(len(bank["zone_names"])):
        index[bank["zone_index_ptr"][z]:bank["zone_index_ptr"][z + 1]] += bank["zone_vertex_ptr"][z]
    vit_tris = bank["body_vertex"][index].astype(np.int32)
    skin_zone = np.zeros(len(bank["base"]), dtype=bool)
    for z, zone in enumerate(str(x) for x in bank["zone_names"]):
        if zone in ("Torso", "Arms", "Legs", "Face"):
            skin_zone[bank["body_vertex"][bank["zone_vertex_ptr"][z]:bank["zone_vertex_ptr"][z + 1]]] = True

    assets, meta, catalogue, report = [], [], [], []
    worlds = {}
    for outfit_id, gender, files in OUTFITS:
        if gender not in worlds:
            # MakeHuman's body of that gender, in metres with the soles at y = 0
            stack = model.stack({"gender": 1.0 if gender == "male" else 0.0, "age": 0.5, "muscle": 0.5, "weight": 0.5,
                                 "height": 0.5, "proportions": 0.5, "cupsize": 0.5, "firmness": 0.5},
                                {"african": 1 / 3, "asian": 1 / 3, "caucasian": 1 / 3})
            mh_dm = model.build(stack)
            ground = model.ground(mh_dm)
            mh_joints_raw = model.joints(mh_dm)
            mh_j = np.zeros((count, 3))
            for bone, (head, _tail) in mh_joints_raw.items():
                game = profile.get(bone, bone)
                if game in names:
                    mh_j[names.index(game)] = (head - np.array([0.0, ground, 0.0])) * 0.1
            mh = Body((mh_dm - np.array([0.0, ground, 0.0])) * 0.1, mh_j, mh_w_all, parents, aims)
            template_dirs = [unit(mh_j[aims[b]] - mh_j[b]) if aims[b] >= 0 else None for b in range(count)]
            v = vitruvian("Gender_Male" if gender == "male" else "Gender_Female")
            vj = np.array([(v[jidx[ptr[2 * b]:ptr[2 * b + 1]]] * jw[ptr[2 * b]:ptr[2 * b + 1], None]).sum(0) for b in range(count)])
            vit = Body(v, vj, vit_w, parents, aims, template_dirs)
            soles = bank["sole_vertex"]
            vit.rest = vit.rest - np.array([0.0, vit.carry(v[soles], vit_w[soles])[:, 1].min(), 0.0])  # soles on y = 0
            vit_t = vit.carry(v, vit_w)
            worlds[gender] = (mh, mh_dm, vit, vit_t, vertex_normals(vit_t, vit_tris),
                              bone_frames(mh, mh.verts, mh_w_all, aims, parents), bone_frames(vit, vit_t, vit_w, aims, parents))
        mh, mh_dm, vit, vit_t, vit_n, (md, ml, mg), (vd, vl, vg) = worlds[gender]
        mh_tree = cKDTree(mh.verts[mh_body])
        mh_normals = vertex_normals(mh.verts, np.array([t for f, g in zip(model.base.faces, model.base.face_group) if g == "body"
                                                        for t in [(f[0][0], f[0][k], f[0][k + 1]) for k in range(1, len(f[0]) - 1)]], dtype=np.int32))
        skin_ids = np.nonzero(skin_zone)[0]
        vit_tree = cKDTree(vit_t[skin_ids])
        neck_skin = vit_w[skin_ids][:, [names.index("Neck"), names.index("Head")]].sum(1)
        slot = len(catalogue)
        kept_parts = []
        for part, rel in enumerate(files):
            clo = mh_formats.load_mhclo(os.path.join(DEFAULT_USER, rel))
            obj = mh_formats.load_obj(clo.obj_file)
            cloth_dm = HumanModel.fit(clo, mh_dm)
            cloth = (cloth_dm - np.array([0.0, model.ground(mh_dm), 0.0])) * 0.1
            w = (mh_w_all[clo.refs] * clo.weights[:, :, None]).sum(1)
            w /= w.sum(1, keepdims=True)
            src, uv, index = render_mesh(triangulate(obj.faces), obj.uvs)
            weld = src[index].astype(np.int32)
            # 3. follow the bones from one body to the other
            moved = np.zeros_like(cloth)
            for b in range(count):
                wb = w[:, b:b + 1]
                if wb.max() <= 0:
                    continue
                rel_p = cloth - mh.rest[b]
                along = rel_p @ md[b]
                radial = rel_p - np.outer(along, md[b])
                moved += wb * (vit.rest[b] + np.outer(along * (vl[b] / ml[b]), vd[b]) + radial * (vg[b] / mg[b]))
            # Neighbouring bones do not stretch alike (a thigh against the hips): the move, not the
            # garment, is smoothed, or the cloth tears where two bones meet (the crotch, a collar).
            moved = cloth + laplacian_smooth(moved - cloth, weld, 12)
            # 4. keep the clearance the garment had over the old body
            dist, near = mh_tree.query(cloth)
            old = np.einsum("ij,ij->i", cloth - mh.verts[mh_body][near], mh_normals[mh_body][near])
            want = np.maximum(old, MIN_CLEARANCE)
            tight = dist < TIGHT_BELOW
            for _ in range(4):
                _d, hit = vit_tree.query(moved)
                q, n = vit_t[skin_ids][hit], vit_n[skin_ids][hit]
                have = np.einsum("ij,ij->i", moved - q, n)
                # Over the neck a collar only keeps out of the skin: a loose neckline had centimetres over the
                # old body, and pushed back to them along the neck's normals (up and out where it meets the
                # shoulders) it climbed the neck -- a T-shirt's collar under the chin.
                restore = tight & (neck_skin[hit] < 0.3)
                push = np.where(restore, want - have, np.maximum(MIN_CLEARANCE - have, 0.0))
                push = np.where(restore, np.clip(push, -0.03, 0.06), push)
                moved += laplacian_smooth(n * push[:, None], weld, SMOOTH_PASSES)
            _d, hit = vit_tree.query(moved)
            have = np.einsum("ij,ij->i", moved - vit_t[skin_ids][hit], vit_n[skin_ids][hit])
            poke = float((have < 0.0).mean())
            report.append((outfit_id, part, os.path.basename(rel), len(cloth), poke))
            if poke > MAX_POKE_SHARE:
                kept_parts = None
                break
            # 5. back to the Vitruvian rest pose, bound to the body
            cloth_w = vit_w[skin_ids][hit]
            rest_pose = vit.uncarry(moved, cloth_w)
            full_tree = cKDTree(vit.verts[skin_ids])
            _d, three = full_tree.query(rest_pose, k=3)
            refs = skin_ids[three]
            weights = np.full((len(cloth), 3), 1.0 / 3.0)
            offsets = rest_pose - vit.verts[refs].mean(1)
            # what the garment hides: the body vertices lying where MakeHuman hid its own
            aligned = np.zeros((len(mh_body), 3))
            for b in range(count):
                wb = mh_w_all[mh_body][:, b:b + 1]
                if wb.max() <= 0:
                    continue
                rel_p = mh.verts[mh_body] - mh.rest[b]
                along = rel_p @ md[b]
                aligned += wb * (vit.rest[b] + np.outer(along * (vl[b] / ml[b]), vd[b]) + (rel_p - np.outer(along, md[b])) * (vg[b] / mg[b]))
            hidden_mh = np.zeros(len(model.base.verts), dtype=bool)
            hidden_mh[clo.delete_verts] = True
            _d, twin = cKDTree(aligned).query(vit_t[skin_ids])
            cover_d, _c = cKDTree(moved).query(vit_t[skin_ids])
            delete = skin_ids[hidden_mh[mh_body][twin] & (cover_d < 0.06)]
            bones, bone_weights = top4(cloth_w)
            fitted = rest_pose[src]
            base = re.sub(r"[^a-z0-9_]+", "_", clo.name.lower()).strip("_")
            textures = {role: f"res://{TEXTURES_REL}/{base}_{role}.webp" for role in ("albedo", "normal", "ao")
                        if os.path.exists(os.path.join(root, TEXTURES_REL, f"{base}_{role}.webp"))}
            kept_parts.append(({
                "refs": refs.astype(np.int32), "weights": weights.astype(np.float32), "offsets": offsets.astype(np.float32),
                "scale_pairs": np.full((3, 2), -1, dtype=np.int32), "scale_ref": np.ones(3, dtype=np.float32),
                "vertex": src.astype(np.int32), "uv": uv, "index": index,
                "tangent": tangents(fitted, vertex_normals(fitted, index), uv, index),
                "bones": bones[src], "bone_weights": bone_weights[src], "delete": delete.astype(np.int32),
            }, {"kind": "outfit", "slot": slot, "part": part, "id": outfit_id, "gender": gender, "name": clo.name}, textures))
        if kept_parts is None:
            continue
        catalogue.append({"id": outfit_id, "gender": gender})
        for arrays, m, textures in kept_parts:
            assets.append((arrays, textures))
            meta.append(m)

    for outfit_id, part, name, n, poke in report:
        print(f"{outfit_id:18s} part {part} {name:28s} {n:6d} vertices, cutting into the body: {poke * 100:5.2f} %"
              + ("" if poke <= MAX_POKE_SHARE else "   -> LEFT OUT"))
    for key in [k for k in bank if k.startswith("asset") and k != "assets_json"]:
        del bank[key]
    textures_map = {}
    for i, (arrays, textures) in enumerate(assets):
        for k, v in arrays.items():
            bank[f"asset{i}_{k}"] = v
        textures_map[str(i)] = textures
    bank["asset_meta_json"] = np.array(json.dumps(meta))
    all_assets = json.loads(str(bank["assets_json"]))
    all_assets["outfit"] = catalogue
    bank["assets_json"] = np.array(json.dumps(all_assets))
    np.savez_compressed(bank_path, **bank)
    with open(os.path.join(os.path.dirname(os.path.abspath(bank_path)), "textures.json"), "w") as f:
        json.dump(textures_map, f, indent=1)
    cat_path = os.path.join(root, "assets/_universe/characters/human/human_catalogue.json")
    runtime = json.load(open(cat_path))
    runtime["assets"]["outfit"] = catalogue
    json.dump(runtime, open(cat_path, "w"), indent=1)
    print(f"{len(catalogue)} outfits kept ({len(assets)} pieces) in {bank_path}")


if __name__ == "__main__":
    main()
