"""
Export the road line layers to the ROAD part of the terrain-modifier pack.
=========================================================================

Road layers are created by setup_planet_project.py (layers/roads.py) as one
PostGIS LineString table per road type — `highway`, `road`, `path`, `trail`, `railway` —
each carrying the `road_type` custom property and the fields `name`, `width`,
`lanes`, `surface`, `speed_limit`, `has_sidewalk` and `has_lighting` — except
`railway`, which only has `name`, `tracks` and `speed_limit` (its bed width is
derived from `tracks`, see export/planet/roads.py railway_half_width_m).
`highway` and `road` also carry an optional `max_slope_degrees`: when set the
road is exported as grade-limited and Godot builds it on a profile with
cuttings, tunnels and viaducts, like a railway.  The
legacy single `roads` table with a per-feature `road_type` field is still read
when present, so older planets export unchanged.

Width
-----
    `width` is the TOTAL road width in metres. The designer may leave it at
    its QGIS auto-fill value or override it; when it is null or <= 0 we fall
    back to HALF_WIDTH_M for the road type. A highway ignores `width`: it is
    `lanes` × LANE_WIDTH_M + MEDIAN_GAP_M (see export/planet/roads.py).
    RoadTerrain.get_half_width_m() applies exactly the same rules on the Godot
    side — keep the two in sync.

Output
------
    <planet>_chunks/parts/roads.dsmpart — per-chunk, per-LOD road pieces, already
    clipped to their HEALPix tile and decimated for their level. Written here and
    then merged into <planet>_chunks/terrainmodifier.pack by link_modifiers.link(),
    which rebuilds the pack from every part present — so running this script
    replaces the roads and leaves craters, rivers and biomes untouched.

    The clipping is what fixes the "two roads, one 2 m above the other" bug: a
    road used to be stored once, globally (a buffered-polygon GeoJSON, retired),
    and every chunk whose bounding box touched it re-extruded the WHOLE
    centerline. Neighbouring chunks at different LODs sampled terrain height at
    different pyramid levels, so the duplicate ribbons ended up at different
    altitudes. Now each tile owns its own disjoint piece and no two chunks can
    draw the same stretch.

Run from QGIS: DyingStar ▸ Export ▸ Roads (the plugin). From the Python console:
    import export_roads; export_roads.run()
"""
import datetime
import os
import json
import math
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
from export.planet import dsmp                          # noqa: E402
from export.planet import roads as roads_lib            # noqa: E402
from export.planet.dsmp_strings import StringTable      # noqa: E402
from export.planet import village_snaps                 # noqa: E402
import ds_project                                       # noqa: E402

# ============================================================
# CONFIGURATION — edit for your planet
# ============================================================
# The planet of the open project, read by _configure() at each run (ds_project.py).
PLANET_NAME = None
# Planet radius in metres — drives the metre → degree conversions (village reroutes, the part).
PLANET_RADIUS = None
# DS_EXPORT_DIR -> export_config.ini [paths] export_dir -> <checkout>/assets/qgis/export.
EXPORT_DIR = None

# Where the villages and cities stand (Horizon's seed) and what their layouts look like (written by
# the game, tools/planettech/layout_snaps_export.gd): the roads are cut out of them and led to their
# road snaps (export/planet/village_snaps.py). The seed defaults to the horizonserver checkout beside
# this repository.
STARTUP_ITEMS = None
LAYOUT_SNAPS = None

# Chunk-export nside, i.e. the finest level heights.pack was baked at. Read from
# <planet>_chunks/manifest.json at run time; this is only the fallback.
EXPORT_NSIDE_FALLBACK = 64

# MUST match PlanetData.max_quadtree_depth in the planet's .tscn (13 on
# tarsis_4). Roads have to be baked down to this level: a chunk finer than the
# deepest baked level would fall back to a shared ancestor tile, and a shared
# tile is exactly how the duplicate-ribbon bug came back. PlanetData re-checks
# this at load time against the real scene value and warns on a mismatch.
MAX_QUADTREE_DEPTH = None

# Vertices per chunk edge — PlanetData.chunk_resolution. Drives the decimation
# tolerance (a quarter of the vertex spacing at each level).
CHUNK_RESOLUTION = 32

# Half-widths and field list now live in
# export/planet/roads.py so RoadTerrain.HALF_WIDTH_M has exactly one Python
# mirror instead of two that can drift.
HALF_WIDTH_M = roads_lib.HALF_WIDTH_M
DEFAULT_HALF_WIDTH_M = roads_lib.DEFAULT_HALF_WIDTH_M
ROAD_FIELDS = roads_lib.ROAD_FIELDS

# True skips the relink, e.g. when chaining several exporters for a single link at the end
# (then call link_modifiers.link('<planet>')) — set by run(no_link=…).
NO_LINK = False


def _configure(no_link=False):
    """Read the open project's planet and the paths; at the start of every run."""
    global PLANET_NAME, PLANET_RADIUS, EXPORT_DIR, MAX_QUADTREE_DEPTH, NO_LINK
    global STARTUP_ITEMS, LAYOUT_SNAPS
    planet = ds_project.planet()
    PLANET_NAME = planet.name
    PLANET_RADIUS = int(planet.radius_m)
    MAX_QUADTREE_DEPTH = planet.max_quadtree_depth
    EXPORT_DIR = link_modifiers.resolve_export_dir()
    NO_LINK = bool(no_link)
    repo = link_modifiers.repo_root() or os.path.abspath(os.path.join(_THIS_DIR, "..", "..", ".."))
    STARTUP_ITEMS = link_modifiers.resolve_path(
        "DS_STARTUP_ITEMS", "startup_items",
        os.path.join(repo, "..", "horizonserver", "ds_genericprops", "startup_items.json"))
    LAYOUT_SNAPS = os.path.join(repo, "assets", "qgis", "export", "layout_snaps.json")


def _legacy_layer_names():
    """Legacy single-table layout: name candidates, in priority order."""
    return ("roads", f"{PLANET_NAME}_roads")


# ============================================================
# Helpers
# ============================================================
def find_layers_by_keyword(keyword):
    """Return project layers whose name contains *keyword* (case-insensitive)."""
    kw = keyword.lower()
    return [l for l in QgsProject.instance().mapLayers().values()
            if kw in l.name().lower()]


def _find_road_layers():
    """``[(layer, road_type), …]`` — one entry per road-type layer.

    New layout first: every line layer carrying the ``road_type`` custom
    property (set by layers/roads.py).  Otherwise the legacy single ``roads``
    layer, whose road type is a per-feature field (road_type=None here).
    """
    layers = [l for l in QgsProject.instance().mapLayers().values()
              if isinstance(l, QgsVectorLayer)
              and l.geometryType() == Qgis.GeometryType.Line]
    typed = [(l, str(l.customProperty("road_type")))
             for l in layers if l.customProperty("road_type", "")]
    if typed:
        return sorted(typed, key=lambda item: item[1])
    for wanted in _legacy_layer_names():
        for l in layers:
            if l.name().lower() == wanted.lower():
                return [(l, None)]
    for l in find_layers_by_keyword("road"):
        if l in layers:
            return [(l, None)]
    return []


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
    straight segment joining them.
    """
    if geom is None or geom.isEmpty():
        return []
    if geom.isMultipart():
        return [part for part in geom.asMultiPolyline() if len(part) >= 2]
    line = geom.asPolyline()
    return [line] if len(line) >= 2 else []


# ============================================================
# Modifier part (the output the game actually reads)
# ============================================================
def export_road_part(roads):
    """Write parts/roads.dsmpart from [roads], then relink terrainmodifier.pack.

    roads: [{"centerline": [(lon, lat), …], "road_type", "width", …}, …] —
    the same dicts the GeoJSON branch builds, so the two outputs can never
    describe different roads.
    """
    # The team's parts and string table first: this export rewrites only its own part.
    link_modifiers.pull_parts(PLANET_NAME, EXPORT_DIR)
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
def prepare(no_link=False):
    """Main thread: read the road layers. Returns the export to run (any thread), or None."""
    _configure(no_link)
    print("=" * 64)
    print(f"  Roads export — planet '{PLANET_NAME}'")
    print("=" * 64)

    road_layers = _find_road_layers()
    if not road_layers:
        print("  ✗ No road layer found. Expected the highway/road/path/trail/railway "
              "layers (created by setup_planet_project.py) or a legacy 'roads' layer.")
        return None
    for layer, road_type in road_layers:
        print(f"  Layer      : {layer.name()} ({layer.featureCount()} features)"
              + (f" → road_type={road_type}" if road_type else " (legacy, per-feature road_type)"))

    m_per_deg = PLANET_RADIUS * math.pi / 180.0
    villages = []
    if os.path.exists(STARTUP_ITEMS) and os.path.exists(LAYOUT_SNAPS):
        villages = village_snaps.load_villages(STARTUP_ITEMS, LAYOUT_SNAPS, PLANET_RADIUS)
        print(f"  Villages   : {len(villages)} (roads cut out of them, led to their snaps)")
    else:
        print(f"  ! Villages not read ({STARTUP_ITEMS} / {LAYOUT_SNAPS}): roads may cross them")
    roads = []
    skipped_short = 0
    defaulted_width = 0

    for feat, road_type in ((f, rt) for layer, rt in road_layers for f in layer.getFeatures()):
        props = {}
        for field in ROAD_FIELDS:
            value = _attr(feat, field)
            if value is not None:
                # json.dump can't serialise QVariant-wrapped values.
                props[field] = value if isinstance(value, (int, float, str)) \
                    else str(value)
        # New layout: the type is the layer, not a field.
        if road_type and not props.get("road_type"):
            props["road_type"] = road_type

        parts = _line_parts(feat.geometry())
        if not parts:
            skipped_short += 1
            continue

        if _attr(feat, "width") is None:
            defaulted_width += 1

        hw_m = _half_width_m(props)
        pieces = []
        for part in parts:
            line = [[float(pt.x()), float(pt.y())] for pt in part]
            pieces.extend(village_snaps.reroute(line, props.get("road_type"), villages, m_per_deg))
        for centerline in pieces:
            road = dict(props)
            road["centerline"] = centerline
            road["width"] = hw_m * 2.0
            roads.append(road)

    print("-" * 64)
    if skipped_short:
        print(f"    skipped (< 2 vertices)  : {skipped_short}")
    if defaulted_width:
        print(f"    width from road_type    : {defaulted_width}")

    def work():
        print("-" * 64)
        export_road_part(roads)

        print("=" * 64)
        print(f"  ✓ Done. {len(roads)} road(s) exported.")
        print("    → In Godot nothing to click: once published, chunks stream the pack.")
        print("=" * 64)
    return work


def run(no_link=False):
    """The whole export, on the calling thread."""
    work = prepare(no_link)
    if work is not None:
        work()


if __name__ == "__main__":
    run()
