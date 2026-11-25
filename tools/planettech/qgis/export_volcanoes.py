"""
Export the volcanoes, lava flows and fumaroles to `parts/volcanoes.dsmpart`,
`parts/lava_flows.dsmpart`, `parts/fumaroles.dsmpart` and relink the pack.
=================================================================================

The layers of layers/volcanoes.py — `volcano` points, `lava_flow` lines,
`fumarole_field` polygons and `fumarole_vent` points — describe WHERE and in
which STYLE; Godot generates the cone, the crater, the lava channel and the
vents at runtime. This script only tiles the features and their parameters
into the terrain-modifier pack (export/planet/volcanoes.py). heights.pack is
not touched.

The lava flows are checked against the ground the exporter can see — the
planet's equirect `<planet>_heightmap.tif` plus the volcanoes' own cones: a
flow whose end is higher than its source is reported (lava never climbs; the
runtime cuts a channel, and warns again from the real relief).

Outputs
-------
    <planet>_chunks/parts/volcanoes.dsmpart
    <planet>_chunks/parts/lava_flows.dsmpart
    <planet>_chunks/parts/fumaroles.dsmpart      then merged into
    <planet>_chunks/terrainmodifier.pack         by link_modifiers.link()

Existing PostGIS tables of the old biome layers are migrated once with
migrate_volcanic_layers.py.

Run from QGIS: DyingStar ▸ Export (the plugin). From the Python console:
    import export_volcanoes; export_volcanoes.run()
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
from export.planet import volcanoes as volcano_lib      # noqa: E402
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


def _geojson(geom):
    if geom is None or geom.isEmpty():
        return None
    return json.loads(geom.asJson())


def _points(geom):
    raw = _geojson(geom)
    if raw is None:
        return []
    if raw.get("type") == "Point":
        c = raw.get("coordinates", [])
        return [(float(c[0]), float(c[1]))] if len(c) >= 2 else []
    if raw.get("type") == "MultiPoint":
        return [(float(c[0]), float(c[1])) for c in raw.get("coordinates", []) if len(c) >= 2]
    return []


def _lines(geom):
    raw = _geojson(geom)
    if raw is None:
        return []
    if raw.get("type") == "LineString":
        parts = [raw.get("coordinates", [])]
    elif raw.get("type") == "MultiLineString":
        parts = raw.get("coordinates", [])
    else:
        parts = []
    return [[(float(p[0]), float(p[1])) for p in part] for part in parts if len(part) >= 2]


def _outer_rings(geom):
    raw = _geojson(geom)
    if raw is None:
        return []
    if raw.get("type") == "Polygon":
        polys = [raw.get("coordinates", [])]
    elif raw.get("type") == "MultiPolygon":
        polys = raw.get("coordinates", [])
    else:
        polys = []
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


def collect(layers, geom_reader, key, label):
    out = []
    for layer in layers:
        n = 0
        for feat in layer.getFeatures():
            props = _fields_of(feat)
            for g in geom_reader(feat.geometry()):
                if key == "point":
                    out.append({"lon": g[0], "lat": g[1], "props": props})
                else:
                    out.append({key: g, "props": props})
                n += 1
        print(f"  {layer.name():<32} {n} {label}")
    return out


def _ground_sampler(volcano_points):
    """(lon, lat) → metres: the equirect heightmap + the noise-free cones, or
    None when the raster is missing (the uphill check is then skipped)."""
    path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_heightmap.tif")
    if not os.path.exists(path):
        print(f"  ! no {path} — lava uphill check skipped")
        return None
    try:
        from osgeo import gdal
    except ImportError:
        print("  ! GDAL not importable — lava uphill check skipped")
        return None
    ds = gdal.Open(path)
    band = ds.GetRasterBand(1)
    arr = band.ReadAsArray()
    h, w = arr.shape
    resolved = []
    for v in volcano_points:
        f = volcano_lib.resolve_volcano(v["props"])
        resolved.append((f, volcano_lib.unit_centre(v["lon"], v["lat"])))

    def sample(lon, lat):
        x = int((lon + 180.0) / 360.0 * w) % w
        y = min(max(int((90.0 - lat) / 180.0 * h), 0), h - 1)
        z = float(arr[y, x])
        for f, c in resolved:
            z += volcano_lib.volcano_height_offset(f, c, lon, lat, PLANET_RADIUS)
        return z
    return sample


# ============================================================
# Export
# ============================================================
def export_parts(volcanoes, flows, fields, vents):
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
        "generated_by": "export_volcanoes.py",
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
    }

    print(f"  Building volcano part (export_nside={export_nside})")
    levels, manifest, warnings = volcano_lib.build_volcano_part(
        volcanoes, PLANET_RADIUS, export_nside, max_quadtree_nside, table,
        planet_name=PLANET_NAME, flows=flows)
    manifest.update(stamp, source_layer="volcano")
    p = link_modifiers.part_path(PLANET_NAME, "volcano", EXPORT_DIR)
    dsmp.write_part(p, dsmp.KIND_VOLCANO, levels, manifest)
    print(f"  ✓ {p} ({os.path.getsize(p) / 1024.0:.1f} KB)")

    print(f"  Building lava part (down to n{max_quadtree_nside})")
    levels, manifest, lava_warnings = volcano_lib.build_lava_part(
        flows, PLANET_RADIUS, export_nside, max_quadtree_nside, table,
        height_at=_ground_sampler(volcanoes), volcanoes=volcanoes)
    warnings += lava_warnings
    manifest.update(stamp, source_layer="lava_flow")
    p = link_modifiers.part_path(PLANET_NAME, "lava", EXPORT_DIR)
    dsmp.write_part(p, dsmp.KIND_LAVA, levels, manifest)
    print(f"  ✓ {p} ({os.path.getsize(p) / 1024.0:.1f} KB)")

    print(f"  Building fumarole part")
    levels, manifest = volcano_lib.build_fumarole_part(
        fields, vents, PLANET_RADIUS, export_nside, max_quadtree_nside, table)
    manifest.update(stamp, source_layer="fumarole_field+fumarole_vent")
    p = link_modifiers.part_path(PLANET_NAME, "fumarole", EXPORT_DIR)
    dsmp.write_part(p, dsmp.KIND_FUMAROLE, levels, manifest)
    print(f"  ✓ {p} ({os.path.getsize(p) / 1024.0:.1f} KB)")

    for w in warnings:
        print(f"  ⚠ {w}")

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
    print(f"  Volcanoes export — planet '{PLANET_NAME}'")
    print("=" * 64)
    volcano_layers = find_layers("volcano", Qgis.GeometryType.Point)
    flow_layers = find_layers("lava_flow", Qgis.GeometryType.Line)
    field_layers = find_layers("fumarole_field", Qgis.GeometryType.Polygon)
    vent_layers = find_layers("fumarole_vent", Qgis.GeometryType.Point)
    if not (volcano_layers or flow_layers or field_layers or vent_layers):
        print("  ✗ No volcano / lava_flow / fumarole layer in the project (re-run "
              "setup_planet_project.py to create them, then migrate_volcanic_layers.py).")
        return None
    volcanoes = collect(volcano_layers, _points, "point", "volcano(es)")
    flows = collect(flow_layers, _lines, "centerline", "lava flow(s)")
    fields = collect(field_layers, _outer_rings, "ring", "fumarole field(s)")
    vents = collect(vent_layers, _points, "point", "fumarole vent(s)")
    print("-" * 64)
    print(f"  {len(volcanoes)} volcano(es), {len(flows)} lava flow(s), "
          f"{len(fields)} fumarole field(s), {len(vents)} vent(s)")

    def work():
        export_parts(volcanoes, flows, fields, vents)
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
