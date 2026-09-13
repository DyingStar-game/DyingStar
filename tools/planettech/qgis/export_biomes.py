"""
Export the biome REGION polygons to `parts/biomes.dsmpart` and relink the pack.
===============================================================================

Every Polygon layer created by setup_planet_project.py carries its biome
identity as QGIS custom properties (`biome_type`, `biome_index`, `color_hex`,
`ds_category`, `ds_priority`); each feature adds its own fields (`rock_type`,
`clarity`, `name`, `density`…).  This script turns them into POPULATE records
of the terrain-modifier pack — see export/planet/biomes.py for the tiling,
the "full / partial" coverage and the overlap rule — and refreshes
assets/_universe/_shared/materials/rocks.json (export_rocks.py) so the rock
slugs in the pack always resolve.

Only the OUTER ring of each polygon is exported (an enclave is another region
drawn on top); a MultiPolygon gives one zone per part.

Outputs
-------
    <planet>_chunks/parts/biomes.dsmpart   then merged into
    <planet>_chunks/terrainmodifier.pack   by link_modifiers.link() — running
    this script replaces the regions and leaves roads, craters… untouched.
    assets/_universe/_shared/materials/rocks.json

Run from the QGIS Python Console:
    exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis/export_biomes.py').read())
"""

import datetime
import json
import os
import sys

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsWkbTypes,
    QgsExpressionContextUtils,
)

# ── Make tools/planettech/qgis importable, then drop stale modules ─────────────
# Same guard as export_roads.py: the console interpreter outlives the session.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__)) \
    if "__file__" in globals() else \
    "/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis"
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
for _name in list(sys.modules):
    _mod = sys.modules.get(_name)
    _file = getattr(_mod, "__file__", None) or ""
    if _file and os.path.abspath(_file).startswith(_THIS_DIR + os.sep) \
            and "export_biomes" not in _name:
        del sys.modules[_name]

import link_modifiers                                   # noqa: E402
import export_rocks                                     # noqa: E402
from export.planet import dsmp                          # noqa: E402
from export.planet import biomes as biomes_lib          # noqa: E402
from export.planet.dsmp_strings import StringTable      # noqa: E402

# ============================================================
# CONFIGURATION
# ============================================================
_project = QgsProject.instance()
_scope = QgsExpressionContextUtils.projectScope(_project)
_proj_planet_name = _scope.variable("planet_name")
_proj_planet_radius = _scope.variable("planet_radius_m")

PLANET_NAME = str(_proj_planet_name) if _proj_planet_name else "tarsis_4"
PLANET_RADIUS = int(float(_proj_planet_radius)) if _proj_planet_radius else 6_356_000

EXPORT_DIR = link_modifiers.resolve_export_dir()
EXPORT_NSIDE_FALLBACK = 64
_proj_depth = _scope.variable("max_quadtree_depth")
MAX_QUADTREE_DEPTH = int(_proj_depth) if _proj_depth else 13

# Set True to skip the relink (chain exporters, link once at the end).
NO_LINK = False


# ============================================================
# Helpers
# ============================================================
def _is_null(value):
    if value is None:
        return True
    if hasattr(value, "isNull"):
        return bool(value.isNull())
    return str(value) == "NULL"


def _plain(value):
    """A JSON-able Python value for a QGIS attribute (QVariant-wrapped or not)."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float, str)):
        return value
    try:
        return float(value)
    except (TypeError, ValueError):
        return str(value)


def _read_export_nside():
    path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks", "manifest.json")
    if not os.path.exists(path):
        print(f"  ! no {path} — assuming export_nside={EXPORT_NSIDE_FALLBACK}")
        return EXPORT_NSIDE_FALLBACK
    with open(path, "r", encoding="utf-8") as fh:
        m = json.load(fh)
    return int(m.get("nside_max") or m.get("nside") or EXPORT_NSIDE_FALLBACK)


def find_region_layers():
    """Polygon layers carrying a `biome_type` custom property, with their identity."""
    out = []
    for layer in QgsProject.instance().mapLayers().values():
        if not isinstance(layer, QgsVectorLayer):
            continue
        if layer.geometryType() != QgsWkbTypes.PolygonGeometry:
            continue
        btype = str(layer.customProperty("biome_type", "") or "")
        if not btype:
            continue
        out.append({
            "layer": layer,
            "biome_type": btype,
            "biome_index": int(layer.customProperty("biome_index", -1)),
            "color_hex": str(layer.customProperty("color_hex", "") or ""),
            "priority": int(layer.customProperty("ds_priority", 0) or 0),
            "category": str(layer.customProperty("ds_category", "") or ""),
        })
    out.sort(key=lambda e: (-e["priority"], e["biome_type"]))
    return out


def _outer_rings(geom):
    """Outer ring(s) of a (Multi)Polygon geometry as [[(lon, lat), …], …]."""
    if geom is None or geom.isEmpty():
        return []
    raw = json.loads(geom.asJson())
    gtype = raw.get("type")
    polys = []
    if gtype == "Polygon":
        polys = [raw.get("coordinates", [])]
    elif gtype == "MultiPolygon":
        polys = raw.get("coordinates", [])
    rings = []
    for rings_of_poly in polys:
        if not rings_of_poly:
            continue
        ring = [(float(p[0]), float(p[1])) for p in rings_of_poly[0]]
        if len(ring) > 1 and ring[0] == ring[-1]:
            ring.pop()
        if len(ring) >= 3:
            rings.append(ring)
    return rings


def collect_zones(entries):
    """The zone dicts export/planet/biomes.py expects, from the project's layers."""
    zones = []
    for e in entries:
        layer = e["layer"]
        n_feat = 0
        n_skipped = 0
        for feat in layer.getFeatures():
            props = {"color_hex": e["color_hex"]} if e["color_hex"] else {}
            for field in feat.fields():
                name = field.name()
                value = feat[name]
                if _is_null(value):
                    continue
                props[name] = _plain(value)
            rings = _outer_rings(feat.geometry())
            if not rings:
                n_skipped += 1
                continue
            for ring in rings:
                zones.append({
                    "ring": ring,
                    "biome_type": e["biome_type"],
                    "biome_index": e["biome_index"],
                    "priority": e["priority"],
                    "props": props,
                })
                n_feat += 1
        print(f"  {e['biome_type']:<44} prio {e['priority']:>3}  {n_feat} zone(s)"
              + (f"  ({n_skipped} empty geometry skipped)" if n_skipped else ""))
    return zones


# ============================================================
# Export
# ============================================================
def export_populate_part(zones):
    parts_dir = link_modifiers.parts_dir_for(PLANET_NAME, EXPORT_DIR)
    os.makedirs(parts_dir, exist_ok=True)

    export_nside = _read_export_nside()
    max_quadtree_nside = 1 << MAX_QUADTREE_DEPTH

    # Shared, append-only string table (see export_roads.py).
    table = StringTable.load(parts_dir)
    baseline = table.as_list()

    print(f"  Building populate part (export_nside={export_nside})")
    levels, manifest = biomes_lib.build_populate_part(
        zones, PLANET_RADIUS, export_nside, max_quadtree_nside, table)

    table.assert_extends(baseline)
    table.save(parts_dir)

    manifest.update({
        "planet_name": PLANET_NAME,
        "source_layer": "regions",
        "generated_by": "export_biomes.py",
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
    })
    part_path = link_modifiers.part_path(PLANET_NAME, "populate", EXPORT_DIR)
    dsmp.write_part(part_path, dsmp.KIND_POPULATE, levels, manifest)
    print(f"  ✓ {part_path} ({os.path.getsize(part_path) / 1024.0:.1f} KB)")

    if NO_LINK:
        print("  NO_LINK set — run link_modifiers.link('%s') when you are done."
              % PLANET_NAME)
        return part_path
    link_modifiers.link(PLANET_NAME, EXPORT_DIR)
    return part_path


def run_export():
    print("=" * 64)
    print(f"  Regions export — planet '{PLANET_NAME}'")
    print("=" * 64)
    entries = find_region_layers()
    if not entries:
        print("  ✗ No region layer found (Polygon layers with a `biome_type` "
              "custom property, created by setup_planet_project.py).")
        return
    zones = collect_zones(entries)
    print("-" * 64)
    print(f"  {len(zones)} zone(s) from {len(entries)} layer(s)")
    export_rocks.write()
    export_populate_part(zones)
    print("=" * 64)
    print("  ✓ Done. Reopen the planet scene: chunks read the pack directly.")
    print("=" * 64)


run_export()
