"""
Write the rock catalogue for Godot.
===================================

    python3 tools/planettech/qgis/export_rocks.py

Dumps ``layers/rocks.py::catalogue()`` — the single source of truth for rock
types (colour ranges, impurities in ppm, sub-minerals, surface flag) — to
``assets/_universe/_shared/materials/rocks.json``, read at runtime by
``RockCatalogue`` (scenes/_universe/environment/terrain/rocks/rock_catalogue.gd).

One global file, not per planet: a zone in the terrain-modifier pack only
carries the rock slug (``rock_type`` prop); everything about the rock comes
from here.  export_biomes.py calls :func:`write` so the file is refreshed with
every biome export; this module also runs standalone (no QGIS needed).
"""

import json
import os
import sys

_THIS_DIR = os.path.dirname(os.path.abspath(__file__)) \
    if "__file__" in globals() else \
    "/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis"
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

VERSION = 1


def repo_root(start=_THIS_DIR):
    d = start
    while d != os.path.dirname(d):
        if os.path.exists(os.path.join(d, "project.godot")):
            return d
        d = os.path.dirname(d)
    return start


def default_path():
    return os.path.join(repo_root(), "assets", "_universe", "_shared", "materials", "rocks.json")


def payload():
    from layers import rocks
    return {"version": VERSION, "rocks": rocks.catalogue()}


def write(path=None):
    path = path or default_path()
    data = payload()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
    print(f"  ✓ {len(data['rocks'])} rocks → {path}")
    return path


if __name__ == "__main__":
    write(sys.argv[1] if len(sys.argv) > 1 else None)
