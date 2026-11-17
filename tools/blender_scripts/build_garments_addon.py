"""Zip the dyingstar_garments Blender addon, with the binding code it needs (tools/character/garments), for the
artists: Edit > Preferences > Add-ons > Install from Disk.

usage: python3 tools/blender_scripts/build_garments_addon.py <output folder>
  -> <output folder>/dyingstar_garments-<version>.zip (drop it in Nextcloud 3D-Assets/_universe/characters/
     humanoids/tools/)
"""
import ast
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "addons", "dyingstar_garments")
SHARED = os.path.join(HERE, "..", "character", "garments")
SHIPPED = ("garment_bind.py", "garment_rules.py")


def version():
    tree = ast.parse(open(os.path.join(ADDON, "__init__.py"), encoding="utf-8").read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "bl_info":
            return ".".join(str(v) for v in ast.literal_eval(node.value)["version"])
    return "0"


def build(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "dyingstar_garments-%s.zip" % version())
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(ADDON)):
            if name.endswith(".py"):
                z.write(os.path.join(ADDON, name), "dyingstar_garments/" + name)
        for name in SHIPPED:
            z.write(os.path.join(SHARED, name), "dyingstar_garments/" + name)
    return path


if __name__ == "__main__":
    print(build(sys.argv[1] if len(sys.argv) > 1 else "build/blender"))
