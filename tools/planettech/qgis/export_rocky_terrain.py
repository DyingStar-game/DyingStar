"""
Export the rocky terrain to `parts/rocky_terrain.dsmpart` and relink the pack.
===============================================================================

The `rocky_terrain` polygons of layers/rocky_terrain.py describe WHERE the
ground is rocky and HOW (ruggedness level + style + overrides); Godot generates
the blocks, ledges, buttes and strata at runtime
(scenes/planet/rock_field_relief.gd). This script resolves each feature's
preset into explicit numbers and tiles it into the terrain-modifier pack (see
export/planet/rocky_terrain.py). heights.pack is not touched; a re-export
re-bakes only the chunks under the zones (PlanetData.mountain_fingerprint in
the chunk cache key).

Outputs
-------
    <planet>_chunks/parts/rocky_terrain.dsmpart   then merged into
    <planet>_chunks/terrainmodifier.pack          by link_modifiers.link()

Run from QGIS: DyingStar ▸ Export (the plugin). From the Python console:
    import export_rocky_terrain; export_rocky_terrain.run()
"""

import datetime
import json
import os
import sys

from qgis.core import (
    Qgis,
    QgsProject,
    QgsVectorLayer,
)

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import link_modifiers                                   # noqa: E402
import ds_project                                       # noqa: E402
from export.planet import dsmp                          # noqa: E402
from export.planet import rocky_terrain as rocky_lib    # noqa: E402
from export.planet.dsmp_strings import StringTable      # noqa: E402

# ============================================================
# CONFIGURATION
# ============================================================
# The planet of the open project, read by _configure() at each run (ds_project.py).
PLANET_NAME = None
PLANET_RADIUS = None
# DS_EXPORT_DIR -> export_config.ini [paths] export_dir -> <checkout>/assets/qgis/export.
EXPORT_DIR = None
EXPORT_NSIDE_FALLBACK = 64
MAX_QUADTREE_DEPTH = None

# Set True to skip the relink (chain exporters, link once at the end).
NO_LINK = False


def _configure(no_link=False):
    """Read the open project's planet and the export folder; at the start of every run."""
    global PLANET_NAME, PLANET_RADIUS, EXPORT_DIR, MAX_QUADTREE_DEPTH, NO_LINK
    planet = ds_project.planet()
    PLANET_NAME = planet.name
    PLANET_RADIUS = int(planet.radius_m)
    MAX_QUADTREE_DEPTH = planet.max_quadtree_depth
    EXPORT_DIR = link_modifiers.resolve_export_dir()
    NO_LINK = bool(no_link)


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


def find_layers(kind, geom_type):
    """Project layers whose `ds_kind` custom property is [kind]."""
    out = []
    for layer in QgsProject.instance().mapLayers().values():
        if not isinstance(layer, QgsVectorLayer):
            continue
        if layer.geometryType() != geom_type:
            continue
        if str(layer.customProperty("ds_kind", "") or "") != kind:
            continue
        out.append(layer)
    return out


def _fields_of(feat):
    props = {}
    for field in feat.fields():
        name = field.name()
        if name in ("fid", "id", "last_updated"):
            continue
        value = feat[name]
        if _is_null(value):
            continue
        props[name] = _plain(value)
    return props


def _outer_rings(geom):
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


def collect_zones(layers):
    zones = []
    for layer in layers:
        n = 0
        for feat in layer.getFeatures():
            props = _fields_of(feat)
            for ring in _outer_rings(feat.geometry()):
                zones.append({"ring": ring, "props": props})
                n += 1
        print(f"  {layer.name():<32} {n} zone(s)")
    return zones



# ============================================================
# Export
# ============================================================
def export_part(zones):
    # The team's parts and string table first: this export rewrites only its own part.
    link_modifiers.pull_parts(PLANET_NAME, EXPORT_DIR)
    parts_dir = link_modifiers.parts_dir_for(PLANET_NAME, EXPORT_DIR)
    os.makedirs(parts_dir, exist_ok=True)
    export_nside = _read_export_nside()
    max_quadtree_nside = 1 << MAX_QUADTREE_DEPTH

    table = StringTable.load(parts_dir)
    baseline = table.as_list()
    stamp = {
        "planet_name": PLANET_NAME,
        "generated_by": "export_rocky_terrain.py",
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }

    print(f"  Building rocky terrain part (export_nside={export_nside})")
    levels, manifest = rocky_lib.build_rocky_part(
        zones, PLANET_RADIUS, export_nside, max_quadtree_nside, table,
        planet_name=PLANET_NAME)
    manifest.update(stamp, source_layer="rocky_terrain")
    path = link_modifiers.part_path(PLANET_NAME, "rocky", EXPORT_DIR)
    dsmp.write_part(path, dsmp.KIND_ROCKY, levels, manifest)
    print(f"  ✓ {path} ({os.path.getsize(path) / 1024.0:.1f} KB)")

    table.assert_extends(baseline)
    table.save(parts_dir)

    if NO_LINK:
        print("  NO_LINK set — run link_modifiers.link('%s') when you are done." % PLANET_NAME)
        return
    link_modifiers.link(PLANET_NAME, EXPORT_DIR)


def prepare(no_link=False):
    """Main thread: read the layers. Returns the export to run (any thread), or None."""
    _configure(no_link)
    print("=" * 64)
    print(f"  Rocky terrain export — planet '{PLANET_NAME}'")
    print("=" * 64)
    layers = find_layers("rocky_terrain", Qgis.GeometryType.Polygon)
    if not layers:
        print("  ✗ No rocky_terrain layer in the project (re-run "
              "setup_planet_project.py to create it).")
        return None
    zones = collect_zones(layers)
    print("-" * 64)
    print(f"  {len(zones)} zone(s)")

    def work():
        export_part(zones)
        print("=" * 64)
        print("  ✓ Done. Reopen the planet scene: chunks read the pack directly.")
        print("=" * 64)
    return work


def run(no_link=False):
    """The whole export, on the calling thread."""
    work = prepare(no_link)
    if work is not None:
        work()


if __name__ == "__main__":
    run()
