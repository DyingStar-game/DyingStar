"""Copy the chosen assets' textures into the project as WebP, with their credit files.

MakeHuman ships 2048-4096 px PNGs (104 MB for the v1 assets): they are re-encoded as WebP (lossy for
colour, high quality for normal maps) and capped at 2048 px (1024 for ambient occlusion), which Godot
imports natively. Each asset gets one `<asset>.txt` credit beside its `<asset>_*` textures, as the
project's credit check expects. Writes textures.json: asset index -> {role: res:// path}.

usage: python3 export_textures.py human_bank.npz <project root>
"""
import json
import os
import re
import sys

import numpy as np
from PIL import Image

ROLES = {"diffuseTexture": "albedo", "normalmapTexture": "normal", "aomapTexture": "ao", "bumpTexture": "albedo"}
CAPS = {"albedo": 2048, "normal": 2048, "ao": 1024}
QUALITY = {"albedo": 90, "normal": 95, "ao": 85}
CREDIT = "MakeHuman - Data Collection AB - https://static.makehumancommunity.org/assets/assetpacks/index.html - CC0\n"
OUT_REL = "assets/_universe/characters/human/textures"


def main():
    bank = np.load(sys.argv[1], allow_pickle=False)
    root = sys.argv[2]
    meta = json.loads(str(bank["asset_meta_json"]))
    out_dir = os.path.join(root, OUT_REL)
    os.makedirs(out_dir, exist_ok=True)
    mapping, written, total = {}, {}, 0
    for i, m in enumerate(meta):
        mat = m["material"]
        roles = {}
        if os.path.exists(mat):
            for key, value in re.findall(r"^(\w+Texture)\s+(\S+)", open(mat).read(), re.M):
                role = ROLES.get(key)
                src = os.path.join(os.path.dirname(mat), value)
                if role and os.path.exists(src) and role not in roles:
                    roles[role] = src
        base = re.sub(r"[^a-z0-9_]+", "_", m["name"].lower()).strip("_")
        mapping[i] = {}
        for role, src in roles.items():
            name = f"{base}_{role}.webp"
            dst = os.path.join(out_dir, name)
            if dst not in written:
                img = Image.open(src)
                img = img.convert("RGBA" if img.mode in ("RGBA", "LA", "P") and role == "albedo" else "RGB")
                cap = CAPS[role]
                if max(img.size) > cap:
                    img = img.resize((cap, cap * img.size[1] // img.size[0]), Image.LANCZOS)
                img.save(dst, "WEBP", quality=QUALITY[role], method=6)
                written[dst] = True
                total += os.path.getsize(dst)
                with open(os.path.join(out_dir, base + ".txt"), "w") as f:
                    f.write(CREDIT)
            mapping[i][role] = "res://" + os.path.relpath(dst, root)
    with open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "textures.json"), "w") as f:
        json.dump(mapping, f, indent=1)
    print(f"{len(written)} textures, {total / 1e6:.1f} MB in {out_dir}")


if __name__ == "__main__":
    main()
