"""The nose's bridge as real faces have it and our sliders could not make it: two new shape keys of the character bank.

Our nose sliders move the bridge's top (Nose_NasalBone, Nose_BridgeProminence) or the whole lower nose
(Nose_Potrusion, Nose_NoseHeight), never its middle: a hump, a scooped bridge, a bridge steeper at its top than at its
bottom could only be made of steps. What real faces need there is measured on Ava-256 (Meta, CC BY-NC 4.0):

  modes  per identity, its registered mesh's outline along the middle of the face minus our head's whose sliders were
         fitted to that mesh (ava_targets.py), along the bridge (0 its root, 1 the top of the tip), in our head's frame;
         the residuals' main directions (PCA, the ~7 % of meshes our fit misses by over 4 mm left out) -> dorsum_modes.json
         (aggregates only: each mode's profile, one standard deviation of real faces, in mm).
  bank   the first two modes made shape keys on the Vitruvian head: Nose_Dorsum_Hump (a hump at the bridge's lower
         half; minus: a scooped bridge) and Nose_Dorsum_Curve (the bridge fuller at its top and hollower at its
         bottom; minus: the other way), a forward move of the face's skin at each height of the bridge, full on the
         middle and fading over the nose's sides; weight 1 is DEVIATIONS standard deviations. Writes them into the bank
         (a run replaces the previous run's), appends their sliders to the catalogue (bank and runtime, tab "nose",
         append-only), their names to tools/localization/localisation.csv and the credit to human_bank.txt.

    python3 -I ava_dorsum.py modes <eval_now dir> dorsum_modes.json
    python3 -I ava_dorsum.py bank dorsum_modes.json build/character/human_bank.npz <project root>
    # then pack the bank (tools/character/human_bank/pack_human_bank.tscn)
"""
import argparse, csv, json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))  # eval_now
sys.path.insert(0, os.path.join(HERE, "..", "..", "flame"))  # transfer_flame: the bank's target encoding

T = np.linspace(-0.15, 1.15, 53)  # along the bridge: 0 its root (the nasion), 1 the top of the tip
TIP_TOP = 4.0  # mm above the nose's furthest point: the bridge's end (t = 1)
MIDDLE = 4.0  # mm either side of our face's middle: the outline's points
OUTLIER = 4.0  # mm: a mesh our fit misses by more along the bridge is left out (its laying failed)
KEYS = {"Nose_Dorsum_Hump": (0, "Nose: bridge hump", "Nez : bosse de l'arête"),
        "Nose_Dorsum_Curve": (1, "Nose: bridge, full top / full bottom", "Nez : arête pleine en haut / en bas")}
DEVIATIONS = 3.0  # a slider's full travel: as many standard deviations of real faces (CharacterAppearance.FLAME_RANGE)
WIDTH = 0.009  # m: the move's fall-off across the face (Gaussian): a bony bridge is 15-20 mm wide
DEPTH = (0.022, 0.010)  # m behind the face's middle at that height: no move .. full (the nose's sides, not the cheeks)
TAPER = (0.10, 0.10)  # of the bridge: the move fades to nothing over this at its root and past the tip's top
CATALOGUE_REL = "assets/_universe/characters/human/human_catalogue.json"
LABELS_REL = "tools/localization/localisation.csv"
CREDIT_REL = "assets/_universe/characters/human/human_bank.txt"
CREDIT = "Meta Platforms - Ava-256 (the nose bridge's shapes, measured on its 3D faces) - https://github.com/facebookresearch/ava-256 - CC BY-NC 4.0"


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# --- modes ---------------------------------------------------------------------------------------------------------

BARY = np.array([[a, b, 1 - a - b] for a in np.linspace(0, 1, 5) for b in np.linspace(0, 1, 5) if a + b <= 1.0 + 1e-9])
BIN = 0.5  # mm: the outlines' height steps


def _mp_points(model, v):
    """MediaPipe's landmarks on our head (eval_now.gd's export: barycentric corners)."""
    return np.array([sum(v[i] * b for i, b in corner) for corner in model["mp"]])


def _envelope(v, model, lo, hi):
    """Our head's outline seen from the side: per BIN of height in [lo, hi) (mm), its furthest point forward (z) over
    the face's surface (every triangle sampled): (heights, furthest)."""
    pts = np.einsum("sj,tjc->tsc", BARY, v[model["tri"]]).reshape(-1, 3)
    ys = np.arange(lo, hi, BIN)
    return ys + 0.5 * BIN, _outline(pts, ys + 0.5 * BIN)


_MODELS = None


def _init(model_dir):
    import eval_now as e
    global _MODELS
    _MODELS = {b: e.load_model(os.path.join(model_dir, "model_" + b)) for b in e.BASES}
    for b in e.BASES:
        _MODELS[b]["mp"] = json.load(open(os.path.join(model_dir, "model_" + b + ".json")))["mediapipe"]


def _outline(pts, ys):
    z = np.full(len(ys), np.nan)
    step = ys[1] - ys[0]
    b = np.floor((pts[:, 1] - (ys[0] - 0.5 * step)) / step).astype(int)
    ok = (b >= 0) & (b < len(ys))
    np.fmax.at(z, b[ok], pts[ok, 2])
    return z


def _fill(z, reach):
    return np.nanmax(np.stack([np.roll(z, k) for k in range(-reach, reach + 1)]), 0)


def _residual(item):
    import eval_now as e
    from ava_common import DATA, load_ply
    ident, frame, out, idx, outer, faces = item
    base = min(out, key=lambda b: out[b]["error"])
    m = _MODELS[base]
    va = load_ply(f"{DATA}/{ident}/{frame}.ply")
    scan = e.crop(va[outer], va[idx])
    ours = e.mesh_of(m, out[base]["weights"])
    laid = e.align(scan, va[idx], ours, m, False)
    r, _, t = e.similarity(ours, laid, False)
    dense = (np.einsum("sj,tjc->tsc", BARY, va[faces]).reshape(-1, 3) - t) @ r  # into our head's frame
    dense = dense[np.abs(dense[:, 0]) < MIDDLE]
    ys, z_ours = _envelope(ours, m, ours[:, 1].min(), ours[:, 1].max())
    z_ours = _fill(z_ours, 2)  # heights no vertex falls in
    z_mesh = _fill(_outline(dense, ys), 1)
    mp = _mp_points(m, ours)
    band = (ys < mp[168, 1] + 15.0) & (ys > mp[2, 1])
    tip = ys[band][np.argmax(z_ours[band])]
    up = (ys > tip + 20.0) & (ys < tip + 50.0)
    root = ys[up][np.argmin(z_ours[up])]
    at = root + T * (tip + TIP_TOP - root)
    return np.interp(at, ys, z_mesh - z_ours, left=np.nan, right=np.nan)


def modes(args):
    from multiprocessing import Pool
    from ava_common import ROOT
    idx = json.load(open(os.path.join(ROOT, "ava_landmarks7.json")))["mp7_vertices"]
    outer = np.load(os.path.join(ROOT, "ava_outer.npy"))
    faces = []
    for line in open(os.path.join(ROOT, "repo", "assets", "face_topology.obj")):
        if line.startswith("f "):
            f = [int(x.split("/")[0]) - 1 for x in line.split()[1:]]
            faces += [[f[0], f[k], f[k + 1]] for k in range(1, len(f) - 1)]
    faces = np.array(faces)
    faces = faces[np.isin(faces, outer).all(1)]
    targets = json.load(open(os.path.join(ROOT, "targets.json")))
    items = [(i, sorted(fr)[0], fr[sorted(fr)[0]], idx, outer, faces) for i, fr in sorted(targets.items())]
    with Pool(8, initializer=_init, initargs=(args.models,)) as pool:
        rows = np.array(pool.map(_residual, items))
    rows = rows[~np.isnan(rows).any(1)]
    kept = rows[np.abs(rows).max(1) < OUTLIER]
    centred = kept - kept.mean(0)
    _, s, vt = np.linalg.svd(centred, full_matrices=False)
    share = s ** 2 / (s ** 2).sum()
    out = {"_doc": "Generated by tools/character/face_survey/ava/ava_dorsum.py modes from Ava-256 (Meta Platforms, CC BY-NC 4.0): "
                   "the nose bridge's outline real faces have and our fitted sliders miss (aggregates only). t: along the "
                   "bridge (0 its root, 1 the top of the tip); mean: the mean miss (mm, forward +); modes: one standard "
                   "deviation of real faces each (mm), the largest first; share: their part of the misses' variance.",
           "identities": int(len(kept)), "t": T.round(4).tolist(), "mean": kept.mean(0).round(3).tolist(), "modes": [], "share": []}
    for k in range(4):
        shape = vt[k] * s[k] / np.sqrt(len(centred))
        shape *= np.sign(shape[np.argmax(np.abs(shape))])  # its largest move forward
        out["modes"].append(shape.round(3).tolist())
        out["share"].append(round(float(share[k]), 3))
        print(f"mode {k}: {share[k] * 100:.0f} % of the misses, 1 sd peaks at {np.abs(shape).max():.2f} mm")
    json.dump(out, open(args.out, "w"), indent=1)
    print(f"{len(kept)} of {len(rows)} identities -> {args.out}")


# --- bank ----------------------------------------------------------------------------------------------------------

def bank_keys(args):
    from transfer_flame import encode, read_targets, write_targets
    data = json.load(open(args.modes))
    bank = dict(np.load(args.bank, allow_pickle=True))
    base = bank["base"].astype(np.float64)
    zones = [str(z) for z in bank["zone_names"]]
    vptr = bank["zone_vertex_ptr"]
    face = np.unique(bank["body_vertex"][vptr[zones.index("Face")]:vptr[zones.index("Face") + 1]])
    # Our head's middle outline: the nose's furthest point, its root (the deepest point 20-50 mm above).
    middle = face[np.abs(base[face, 0]) < 0.002]
    tip = middle[np.argmax(base[middle, 2])]
    tip_y = base[tip, 1]
    heights = np.arange(base[middle, 1].min(), base[middle, 1].max(), 0.001)
    outline = _fill(_outline(base[middle], heights), 1)  # the middle's outline: per mm of height, its furthest out
    up = (heights > tip_y + 0.020) & (heights < tip_y + 0.050)
    root_y = heights[up][np.argmin(outline[up])]
    end_y = tip_y + TIP_TOP / 1000.0
    print(f"bridge: root {root_y * 1000:.1f} mm, tip {tip_y * 1000:.1f} mm ({(root_y - end_y) * 1000:.1f} mm long)")
    t = (root_y - base[face, 1]) / (root_y - end_y)
    ok = np.isfinite(outline)
    front = np.interp(base[face, 1], heights[ok], outline[ok])  # the middle's depth at each vertex's height
    weight = (np.exp(-(base[face, 0] / WIDTH) ** 2)
              * smoothstep(-DEPTH[0], -DEPTH[1], base[face, 2] - front)
              * smoothstep(T[0], T[0] + TAPER[0], t) * smoothstep(T[-1], T[-1] - TAPER[1], t))
    grid = np.array(data["t"])
    targets = [x for x in read_targets(bank) if x[0] not in KEYS]
    for key, (mode, _en, _fr) in KEYS.items():
        profile = np.array(data["modes"][mode]) / 1000.0 * DEVIATIONS  # m at weight 1
        delta = np.zeros_like(base)
        delta[face, 2] = np.interp(t, grid, profile, left=0.0, right=0.0) * weight
        targets.append((key, *encode(delta)))
        print(f"{key}: mode {mode}, {np.abs(delta[:, 2]).max() * 1000:.2f} mm at most, "
              f"{int((np.abs(delta[:, 2]) > 1e-5).sum())} vertices moved")
    write_targets(bank, targets)
    catalogue = json.loads(str(bank["catalogue_json"]))
    known = {c["key"] for c in catalogue}
    for key in KEYS:
        if key not in known:
            catalogue.append({"key": key, "tab": "nose", "label": "%%CHAR_MOD_" + key.upper(), "unipolar": False, "signed": True,
                              "negative": [], "positive": [key]})
    bank["catalogue_json"] = np.array(json.dumps(catalogue))
    np.savez_compressed(args.bank, **bank)
    runtime_path = os.path.join(args.root, CATALOGUE_REL)
    runtime = json.load(open(runtime_path))
    known = {m["key"] for m in runtime["modifiers"]}
    for key in KEYS:
        if key not in known:
            runtime["modifiers"].append({"key": key, "tab": "nose", "label": "%%CHAR_MOD_" + key.upper(), "unipolar": False})
    json.dump(runtime, open(runtime_path, "w"), indent=1)
    labels_path = os.path.join(args.root, LABELS_REL)
    text = open(labels_path, encoding="utf-8").read()
    columns = len(next(csv.reader([text.split("\n", 1)[0]])))
    with open(labels_path, "a", encoding="utf-8", newline="") as f:
        if not text.endswith("\n"):
            f.write("\n")
        writer = csv.writer(f, lineterminator="\n")
        for key, (_mode, en, fr) in KEYS.items():
            label = "%%CHAR_MOD_" + key.upper()
            if label + "," not in text:
                writer.writerow([label, en, fr] + [""] * (columns - 3))
    credit_path = os.path.join(args.root, CREDIT_REL)
    lines = [line.rstrip("\n") for line in open(credit_path)]
    if CREDIT not in lines:
        lines.append(CREDIT)
    open(credit_path, "w").write("\n".join(lines) + "\n")
    print(f"{len(KEYS)} bridge keys in {args.bank}; catalogue {len(runtime['modifiers'])} sliders")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    m = sub.add_parser("modes")
    m.add_argument("models")
    m.add_argument("out")
    b = sub.add_parser("bank")
    b.add_argument("modes")
    b.add_argument("bank")
    b.add_argument("root")
    args = ap.parse_args()
    modes(args) if args.command == "modes" else bank_keys(args)


if __name__ == "__main__":
    main()
