"""
Export the `roads` line layer to the buffered-polygon GeoJSON Godot renders.
===========================================================================

The roads layer is created by setup_planet_project.py as a PostGIS LineString
table (EPSG:4326) with the fields `name`, `road_type`, `width`, `lanes`,
`surface`, `speed_limit`, `has_sidewalk` and `has_lighting`.

Why polygons and not lines
--------------------------
    Godot loads this file through BiomeQuery, whose feature parser ACCEPTS
    ONLY `Polygon` geometry — a raw LineString export is silently dropped.
    So each road is buffered into a polygon used for coarse chunk-bbox
    detection, and the original line is preserved in `properties.centerline`.
    The visible ribbon is extruded from that centerline by planet_chunk.gd,
    so the buffer is deliberately DETECTION_MULTIPLIER× wider than the road:
    it only has to guarantee that a chunk crossed by a narrow trail is not
    missed by the bounding-box test.

Width
-----
    `width` is the TOTAL road width in metres. The designer may leave it at
    its QGIS auto-fill value or override it; when it is null or <= 0 we fall
    back to HALF_WIDTH_M for the road type. RoadTerrain.get_half_width_m()
    applies exactly the same rule on the Godot side — keep the two in sync.

Two outputs
-----------
    1. <planet>_chunks/parts/roads.dsmpart  — THE ONE THE GAME USES.
       Per-chunk, per-LOD road pieces, already clipped to their HEALPix tile and
       decimated for their level. Written here and then merged into
       <planet>_chunks/terrainmodifier.pack by link_modifiers.link(), which
       rebuilds the pack from every part present — so running this script
       replaces the roads and leaves craters, rivers and biomes untouched.

       The clipping is what fixes the "two roads, one 2 m above the other" bug:
       a road used to be stored once, globally, and every chunk whose bounding
       box touched it re-extruded the WHOLE centerline. Neighbouring chunks at
       different LODs sampled terrain height at different pyramid levels, so the
       duplicate ribbons ended up at different altitudes. Now each tile owns its
       own disjoint piece and no two chunks can draw the same stretch.

    2. <planet>_roads_buffered.json — the legacy buffered-polygon GeoJSON,
       still read by BiomeQuery while the runtime transitions to the pack.
       It will stop being written once PlanetData.roads_geojson is retired.

Legacy GeoJSON layout
---------------------
    <EXPORT_DIR>/<planet>_roads_buffered.json

    {
      "type": "FeatureCollection",
      "crs": {"type": "name", "properties": {"name": "EPSG:4326"}},
      "features": [
        {"type": "Feature",
         "geometry": {"type": "Polygon", "coordinates": [[[lon, lat], ...]]},
         "properties": {"name": "...", "road_type": "road", "surface": "asphalt",
                        "lanes": 2, "width": 6.0,
                        "centerline": [[lon, lat], ...]}}
      ]
    }

    PlanetData.roads_geojson must point at it, e.g.
    "assets/qgis/export/tarsis_4_roads_buffered.json" (already set on tarsis_4).

Run from the QGIS Python Console:
    exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/qgis/export_roads.py').read())
"""
import datetime
import os
import json
import math
import sys

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsGeometry,
    QgsWkbTypes,
    QgsExpressionContextUtils,
)

# ── Make tools/qgis importable, then drop stale modules ──────────────────
# The QGIS Python interpreter outlives the console session, so an edited
# helper stays cached and you debug code that is no longer on disk. Same guard
# as export_elevation.py — copy it into any new exporter.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__)) \
    if "__file__" in globals() else \
    "/datas/developpement/sources/DyingStar-game/DyingStar/tools/qgis"
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
for _name in list(sys.modules):
    _mod = sys.modules.get(_name)
    _file = getattr(_mod, "__file__", None) or ""
    if _file and os.path.abspath(_file).startswith(_THIS_DIR + os.sep) \
            and "export_roads" not in _name:
        del sys.modules[_name]

import link_modifiers                                   # noqa: E402
from export.planet import dsmp                          # noqa: E402
from export.planet import roads as roads_lib            # noqa: E402
from export.planet.dsmp_strings import StringTable      # noqa: E402

# ============================================================
# CONFIGURATION — edit for your planet
# ============================================================
_project = QgsProject.instance()
_proj_planet_name = QgsExpressionContextUtils.projectScope(_project).variable("planet_name")
_proj_planet_radius = QgsExpressionContextUtils.projectScope(_project).variable("planet_radius_m")

PLANET_NAME = str(_proj_planet_name) if _proj_planet_name else "tarsis_4"
# Planet radius in metres — drives the metre → degree conversion of the buffer.
PLANET_RADIUS = int(_proj_planet_radius) if _proj_planet_radius else 6_356_000

# DS_EXPORT_DIR -> export_config.ini [paths] export_dir -> the historical path.
EXPORT_DIR = link_modifiers.resolve_export_dir()

# Chunk-export nside, i.e. the finest level heights.pack was baked at. Read from
# <planet>_chunks/manifest.json at run time; this is only the fallback.
EXPORT_NSIDE_FALLBACK = 64

# MUST match PlanetData.max_quadtree_depth in the planet's .tscn (13 on
# tarsis_4). Roads have to be baked down to this level: a chunk finer than the
# deepest baked level would fall back to a shared ancestor tile, and a shared
# tile is exactly how the duplicate-ribbon bug came back. PlanetData re-checks
# this at load time against the real scene value and warns on a mismatch.
_proj_depth = QgsExpressionContextUtils.projectScope(_project).variable(
    "max_quadtree_depth")
MAX_QUADTREE_DEPTH = int(_proj_depth) if _proj_depth else 13

# Vertices per chunk edge — PlanetData.chunk_resolution. Drives the decimation
# tolerance (a quarter of the vertex spacing at each level).
CHUNK_RESOLUTION = 32

# Half-widths, detection multiplier and field list now live in
# export/planet/roads.py so RoadTerrain.HALF_WIDTH_M has exactly one Python
# mirror instead of two that can drift.
HALF_WIDTH_M = roads_lib.HALF_WIDTH_M
DEFAULT_HALF_WIDTH_M = roads_lib.DEFAULT_HALF_WIDTH_M
DETECTION_MULTIPLIER = roads_lib.DETECTION_MULTIPLIER
ROAD_FIELDS = roads_lib.ROAD_FIELDS

# Segments per quarter circle when buffering (QgsGeometry.buffer).
BUFFER_SEGMENTS = 8

# Set True to skip the relink, e.g. when chaining several exporters and you want
# a single link at the end (then call link_modifiers.link('<planet>')).
NO_LINK = False

# Layer name candidates, in priority order, before the substring search.
_LAYER_NAMES = ("roads", f"{PLANET_NAME}_roads")


# ============================================================
# Helpers
# ============================================================
def find_layers_by_keyword(keyword):
    """Return project layers whose name contains *keyword* (case-insensitive)."""
    kw = keyword.lower()
    return [l for l in QgsProject.instance().mapLayers().values()
            if kw in l.name().lower()]


def _find_roads_layer():
    """Exact name match first, then any line vector layer named like a road one."""
    layers = list(QgsProject.instance().mapLayers().values())
    for wanted in _LAYER_NAMES:
        for l in layers:
            if l.name().lower() == wanted.lower() and isinstance(l, QgsVectorLayer):
                return l
    for l in find_layers_by_keyword("road"):
        if isinstance(l, QgsVectorLayer) \
                and l.geometryType() == QgsWkbTypes.LineGeometry:
            return l
    return None


def _is_null(value):
    """True for a NULL attribute, whether PyQGIS hands it back as None or QVariant."""
    if value is None:
        return True
    if hasattr(value, "isNull"):
        return bool(value.isNull())
    return str(value) == "NULL"


def _attr(feat, name):
    """Raw attribute value, or None when the field is absent or NULL."""
    if feat.fields().indexOf(name) < 0:
        return None
    value = feat[name]
    return None if _is_null(value) else value


def _half_width_m(props):
    """Per-feature `width` when the designer set it, else the road_type default."""
    return roads_lib.half_width_m(props)


def _read_export_nside():
    """Finest nside heights.pack was baked at, from the planet's manifest.json.

    Craters, biomes and radial features are stored at this level, so the road
    part records it too and the linker refuses to merge parts that disagree.
    """
    path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks", "manifest.json")
    if not os.path.exists(path):
        print(f"  ! no {path} — assuming export_nside={EXPORT_NSIDE_FALLBACK}")
        return EXPORT_NSIDE_FALLBACK
    with open(path, "r", encoding="utf-8") as fh:
        m = json.load(fh)
    return int(m.get("nside_max") or m.get("nside") or EXPORT_NSIDE_FALLBACK)


def _line_parts(geom):
    """Every polyline of [param geom] as its own list of QgsPointXY.

    Multipart roads are split into one feature per part rather than merged:
    concatenating disjoint parts into a single centerline would invent a
    straight segment joining them, and buffering them together can yield a
    MultiPolygon that BiomeQuery would reject.
    """
    if geom is None or geom.isEmpty():
        return []
    if geom.isMultipart():
        return [part for part in geom.asMultiPolyline() if len(part) >= 2]
    line = geom.asPolyline()
    return [line] if len(line) >= 2 else []


def _polygons_of(geom):
    """GeoJSON geometry dicts for [param geom], one per polygon part."""
    raw = json.loads(geom.asJson())
    gtype = raw.get("type")
    if gtype == "Polygon":
        return [raw]
    if gtype == "MultiPolygon":
        return [{"type": "Polygon", "coordinates": rings}
                for rings in raw.get("coordinates", [])]
    return []


# ============================================================
# Modifier part (the output the game actually reads)
# ============================================================
def export_road_part(roads):
    """Write parts/roads.dsmpart from [roads], then relink terrainmodifier.pack.

    roads: [{"centerline": [(lon, lat), …], "road_type", "width", …}, …] —
    the same dicts the GeoJSON branch builds, so the two outputs can never
    describe different roads.
    """
    parts_dir = link_modifiers.parts_dir_for(PLANET_NAME, EXPORT_DIR)
    os.makedirs(parts_dir, exist_ok=True)

    export_nside = _read_export_nside()
    max_quadtree_nside = 1 << MAX_QUADTREE_DEPTH

    # The table is shared with every other exporter and is APPEND-ONLY: ids
    # already handed out must keep pointing at the same strings, or the records
    # craters.dsmpart wrote last week would decode to the wrong biome names.
    table = StringTable.load(parts_dir)
    baseline = table.as_list()

    print(f"  Building road part (export_nside={export_nside}, "
          f"quadtree=n{max_quadtree_nside}, res={CHUNK_RESOLUTION})")
    levels, manifest = roads_lib.build_road_part(
        roads, PLANET_RADIUS, export_nside, max_quadtree_nside, table,
        res_max=CHUNK_RESOLUTION)

    table.assert_extends(baseline)
    table.save(parts_dir)

    manifest.update({
        "planet_name": PLANET_NAME,
        "source_layer": "roads",
        "generated_by": "export_roads.py",
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
    })
    part_path = link_modifiers.part_path(PLANET_NAME, "road", EXPORT_DIR)
    dsmp.write_part(part_path, dsmp.KIND_ROAD, levels, manifest)
    print(f"  ✓ {part_path} ({os.path.getsize(part_path) / 1024.0:.1f} KB)")

    if NO_LINK:
        print("  NO_LINK set — run link_modifiers.link('%s') when you are done."
              % PLANET_NAME)
        return part_path
    link_modifiers.link(PLANET_NAME, EXPORT_DIR)
    return part_path


# ============================================================
# Export
# ============================================================
def run_export():
    print("=" * 64)
    print(f"  Roads export — planet '{PLANET_NAME}'")
    print("=" * 64)

    layer = _find_roads_layer()
    if layer is None:
        print("  ✗ No roads layer found. Expected a line layer named 'roads' "
              "(created by setup_planet_project.py).")
        return
    print(f"  Layer      : {layer.name()} ({layer.featureCount()} features)")

    m_per_deg = PLANET_RADIUS * math.pi / 180.0
    features = []
    # Same road dicts feed the pack part, so the two outputs cannot disagree.
    roads = []
    skipped_short = 0
    skipped_empty_buffer = 0
    defaulted_width = 0

    for feat in layer.getFeatures():
        props = {}
        for field in ROAD_FIELDS:
            value = _attr(feat, field)
            if value is not None:
                # json.dump can't serialise QVariant-wrapped values.
                props[field] = value if isinstance(value, (int, float, str)) \
                    else str(value)

        parts = _line_parts(feat.geometry())
        if not parts:
            skipped_short += 1
            continue

        if _attr(feat, "width") is None:
            defaulted_width += 1

        for part in parts:
            hw_m = _half_width_m(props)
            centerline = [[float(pt.x()), float(pt.y())] for pt in part]

            road = dict(props)
            road["centerline"] = centerline
            road["width"] = hw_m * 2.0
            roads.append(road)

            part_geom = QgsGeometry.fromPolylineXY(part)
            buffered = part_geom.buffer(
                (hw_m * DETECTION_MULTIPLIER) / m_per_deg, BUFFER_SEGMENTS)
            polygons = _polygons_of(buffered) if not buffered.isEmpty() else []
            if not polygons:
                skipped_empty_buffer += 1
                continue

            for polygon in polygons:
                part_props = dict(props)
                part_props["centerline"] = centerline
                # Total width in metres — RoadTerrain.get_half_width_m() halves it.
                part_props["width"] = hw_m * 2.0
                features.append({
                    "type": "Feature",
                    "geometry": polygon,
                    "properties": part_props,
                })

    payload = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "EPSG:4326"}},
        "features": features,
    }

    os.makedirs(EXPORT_DIR, exist_ok=True)
    out_path = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_roads_buffered.json")
    tmp_path = out_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as out:
        json.dump(payload, out, ensure_ascii=False)
    os.replace(tmp_path, out_path)

    by_type = {}
    for feature in features:
        key = feature["properties"].get("road_type") or "(none)"
        by_type[key] = by_type.get(key, 0) + 1

    size_kb = os.path.getsize(out_path) / 1024.0
    print("-" * 64)
    print(f"  legacy GeoJSON: {len(features)} polygon(s) → {out_path} "
          f"({size_kb:.1f} KB)")
    for key in sorted(by_type):
        print(f"    {key:<14} {by_type[key]}")
    if skipped_short:
        print(f"    skipped (< 2 vertices)  : {skipped_short}")
    if skipped_empty_buffer:
        print(f"    skipped (empty buffer)  : {skipped_empty_buffer}")
    if defaulted_width:
        print(f"    width from road_type    : {defaulted_width}")

    print("-" * 64)
    export_road_part(roads)

    print("=" * 64)
    print(f"  ✓ Done. {len(roads)} road(s) exported.")
    print("    → In Godot nothing to click: chunks read terrainmodifier.pack "
          "directly. Reopen the scene to regenerate the preview chunks.")
    print("=" * 64)


run_export()
