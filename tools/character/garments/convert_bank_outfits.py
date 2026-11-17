"""Turn the bank's MakeHuman outfits into garment files, as they are (no re-binding, the same vertices to the bit).

Each outfit piece -- a suit, its shoes -- becomes `assets/_universe/characters/human/garments/<id>/<id>.dsgarment`
with its textures and credit beside it, an entry at the end of `garments` in human_catalogue.json, and each old
outfit (`assets.outfit`, kept for the characters saved before garments) learns which garments it now is.

A shoe refitted on the man and on the woman is two garments (MakeHuman's feet differ by up to 5 cm): the first is
`mh_<shoe>`, the other `mh_<shoe>_<gender>`, which uses the first one's textures (meta "textures").

usage: python3 tools/character/garments/convert_bank_outfits.py build/character/human_bank.npz <project root> \
           [--textures build/character/textures.json] [--strip]
  --strip  also takes the outfits out of the bank npz (and textures.json): the game wears garments now. Repack the
           bank afterwards (tools/character/human_bank/pack_human_bank.tscn).
"""
import json
import os
import shutil
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "human_bank"))
import garment_bind as gb  # noqa: E402
import garment_rules  # noqa: E402
from catalogue_guard import guard  # noqa: E402

GARMENTS_REL = "assets/_universe/characters/human/garments"
CATALOGUE_REL = "assets/_universe/characters/human/human_catalogue.json"
CREDIT = "MakeHuman - Data Collection AB - https://static.makehumancommunity.org/assets/assetpacks/index.html - CC0\n"
# GDD fields of MakeHuman's pieces: a casual / work suit is a shirt and trousers in one mesh (torso, arms, legs;
# clothing on underwear, blocks like trousers); shoes go on socks.
SUIT = {"zones": ["3", "4", "8"], "support": 0, "layer": 1, "access": 0, "material": "cloth", "hides": []}
SHOES = {"zones": ["9"], "support": 0, "layer": 1, "access": 0, "material": "leather", "hides": []}
NAMES = {  # en, fr (as they look on a body)
    "male_casualsuit01": ("Denim shirt and jeans", "Chemise en jean et jean"),
    "male_casualsuit02": ("Long-sleeved T-shirt and jeans", "T-shirt à manches longues et jean"),
    "male_casualsuit04": ("T-shirt and jeans", "T-shirt et jean"),
    "male_worksuit01": ("Overalls and T-shirt", "Salopette et T-shirt"),
    "female_casualsuit01": ("T-shirt and jeans", "T-shirt et jean"),
    "female_casualsuit02": ("T-shirt and denim shorts", "T-shirt et short en jean"),
    "shoes01": ("Brown shoes", "Chaussures marron"),
    "shoes03": ("Black shoes", "Chaussures noires"),
    "shoes04": ("Grey shoes", "Chaussures grises"),
}


def garment_ids(meta):
    """Per bank asset index (outfit pieces only): (garment id, the id whose textures it uses, is it new)."""
    out, seen = {}, {}
    for i, m in enumerate(meta):
        if m["kind"] != "outfit":
            continue
        name = m["name"]
        key = (name, m["gender"])
        if key in seen:
            out[i] = (seen[key], seen[key], False)
            continue
        first = next((gid for (n, _g), gid in seen.items() if n == name), None)
        gid = "mh_" + name if first is None else "mh_%s_%s" % (name, m["gender"])
        seen[key] = gid
        out[i] = (gid, first or gid, True)
    return out


def move(root, src_rel, dst_rel):
    """git mv (keeps history and the .import's uid), or a plain move outside git."""
    src, dst = os.path.join(root, src_rel), os.path.join(root, dst_rel)
    if not os.path.exists(src) or os.path.exists(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if subprocess.call(["git", "-C", root, "mv", src_rel, dst_rel], stderr=subprocess.DEVNULL) != 0:
        shutil.move(src, dst)


def main():
    bank_path, root = sys.argv[1], os.path.abspath(sys.argv[2])
    textures_path = sys.argv[sys.argv.index("--textures") + 1] if "--textures" in sys.argv else \
        os.path.join(os.path.dirname(os.path.abspath(bank_path)), "textures.json")
    bank = dict(np.load(bank_path, allow_pickle=False))
    meta = json.loads(str(bank["asset_meta_json"]))
    textures = json.load(open(textures_path)) if os.path.exists(textures_path) else {}
    signature = gb.body_signature(bank["base"], gb.bank_triangles(bank))
    ids = garment_ids(meta)
    catalogue_path = os.path.join(root, CATALOGUE_REL)
    catalogue = json.load(open(catalogue_path))
    entries = list(catalogue.get("garments", []))
    known = {e["id"] for e in entries}
    outfit_garments = {}

    for i, (gid, tex_id, new) in ids.items():
        m = meta[i]
        outfit_garments.setdefault(m["slot"], []).append(gid)
        if not new:
            continue
        fields = SUIT if m["part"] == 0 else SHOES
        name_en, name_fr = NAMES.get(m["name"], (m["name"], m["name"]))
        if tex_id != gid:
            name_en, name_fr = name_en + (" (women)" if m["gender"] == "female" else " (men)"), \
                name_fr + (" (femmes)" if m["gender"] == "female" else " (hommes)")
        garment_meta = dict(fields, id=gid, gender=m["gender"], binding="skin", name_en=name_en, name_fr=name_fr,
                            bound_on=m["gender"], body_signature=signature)
        if tex_id != gid:
            garment_meta["textures"] = tex_id
        folder = os.path.join(root, GARMENTS_REL, gid)
        os.makedirs(folder, exist_ok=True)
        arrays = {k: bank["asset%d_%s" % (i, k)] for k in gb.ARRAY_KEYS}
        gb.write_garment(os.path.join(folder, gid + ".dsgarment"), arrays, garment_meta)
        with open(os.path.join(folder, gid + ".txt"), "w") as f:
            f.write(CREDIT)
        if tex_id == gid:
            for role, res in textures.get(str(i), {}).items():
                src_rel = res.replace("res://", "")
                ext = os.path.splitext(src_rel)[1]
                dst_rel = "%s/%s/%s_%s%s" % (GARMENTS_REL, gid, gid, role, ext)
                move(root, src_rel, dst_rel)
                move(root, src_rel + ".import", dst_rel + ".import")
                old_credit = os.path.join(root, os.path.dirname(src_rel), m["name"] + ".txt")
                if os.path.exists(old_credit):
                    subprocess.call(["git", "-C", root, "rm", "-q", "--cached", os.path.relpath(old_credit, root)],
                                    stderr=subprocess.DEVNULL)
                    os.remove(old_credit)
        if gid not in known:
            entries.append({k: garment_meta[k] for k in ("id", "zones", "support", "layer", "access", "hides",
                                                         "material", "gender")})
            known.add(gid)
        print("%-28s %6d vertices  %s" % (gid, len(arrays["refs"]), garment_rules.code_of(garment_meta)))

    new_catalogue = dict(catalogue)
    new_catalogue["garments"] = entries
    for slot, gids in outfit_garments.items():
        new_catalogue["assets"]["outfit"][slot]["garments"] = gids
    guard(catalogue_path, new_catalogue, ["garments", "assets/outfit"])
    with open(catalogue_path, "w") as f:
        json.dump(new_catalogue, f, indent=1, ensure_ascii=False)
        f.write("\n")

    if "--strip" in sys.argv:
        keep = [i for i, m in enumerate(meta) if m["kind"] != "outfit"]
        stripped = {k: v for k, v in bank.items() if not (k.startswith("asset") and k[5:6].isdigit())}
        new_textures = {}
        for new_i, old_i in enumerate(keep):
            prefix = "asset%d_" % old_i
            for key in bank:
                if key.startswith(prefix):
                    stripped["asset%d_%s" % (new_i, key[len(prefix):])] = bank[key]
            if str(old_i) in textures:
                new_textures[str(new_i)] = textures[str(old_i)]
        stripped["asset_meta_json"] = np.array(json.dumps([meta[i] for i in keep]))
        np.savez_compressed(bank_path, **stripped)
        with open(textures_path, "w") as f:
            json.dump(new_textures, f, indent=1)
        print("bank: %d outfit pieces taken out, %d assets left" % (len(meta) - len(keep), len(keep)))


if __name__ == "__main__":
    main()
