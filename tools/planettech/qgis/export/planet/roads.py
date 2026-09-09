"""
Shared road definitions and the ROAD part builder.

The width table below is the ONLY Python mirror of RoadTerrain.HALF_WIDTH_M
(scenes/planet/road/road_terrain.gd). It used to be duplicated in
export_roads.py; both now import it from here so the two cannot drift.

The part builder is pure (stdlib + modifier_geom + dsmp, no QGIS import) so it
can be unit-tested with plain python3; only find_roads_layer() and
collect_roads_from_layer() touch PyQGIS, and they import it lazily.
"""
import math

from . import dsmp
from . import modifier_geom as mg

#: Half-widths per road_type in metres — MUST match RoadTerrain.HALF_WIDTH_M.
HALF_WIDTH_M = {
    "highway": 6.0,   # 12 m total
    "road": 3.0,      # 6 m
    "path": 1.0,      # 2 m
    "trail": 0.5,     # 1 m
}
DEFAULT_HALF_WIDTH_M = 0.5

#: The detection polygon in the legacy GeoJSON is wider than the visual road so
#: chunk-level bbox sampling catches narrow roads — RoadTerrain.DETECTION_MULTIPLIER.
#: The pack does not need it (tiles are partitioned, not bbox-tested), but the
#: GeoJSON export still writes it while BiomeQuery remains the fallback source.
DETECTION_MULTIPLIER = 3.0

#: Attributes copied verbatim from the QGIS layer.
ROAD_FIELDS = ("name", "road_type", "width", "lanes", "surface",
               "speed_limit", "has_sidewalk", "has_lighting")

#: Roads with fewer points than this after decimation are dropped: a ribbon
#: needs two points to be extruded at all.
MIN_POINTS = 2


def half_width_m(props):
    """Per-feature `width` when the designer set one, else the road_type default.

    Mirrors RoadTerrain.get_half_width_m(): `width` is the TOTAL width in metres.
    """
    width = props.get("width")
    if width is not None:
        try:
            if float(width) > 0.0:
                return float(width) * 0.5
        except (TypeError, ValueError):
            pass
    road_type = props.get("road_type") or "trail"
    return HALF_WIDTH_M.get(road_type, DEFAULT_HALF_WIDTH_M)


# ── Part building ───────────────────────────────────────────────────────

def build_road_part(roads, radius_m, export_nside, max_quadtree_nside, table,
                    res_max=32, verbose=True):
    """Build the ROAD part's levels and manifest.

    roads: [{"centerline": [(lon, lat), …], "road_type", "width", "lanes",
             "surface", "name"}, …] — `width` is the TOTAL width in metres.
    table: a dsmp_strings.StringTable, interned into (and left dirty for the
           caller to save).

    Returns (levels, manifest) ready for dsmp.write_part().

    Roads are PARTITIONED, never duplicated: see modifier_geom.partition_polyline.
    Every point of a road ends up in exactly one tile at every level, which is
    what stops two chunks at different LODs from both extruding it.
    """
    policy = mg.level_policy(export_nside, max_quadtree_nside)["road"]
    levels_ns = mg.levels_for(policy)
    mpd = mg.m_per_deg(radius_m)

    prepared = []
    for fid, r in enumerate(roads):
        cl = [(float(p[0]), float(p[1])) for p in r.get("centerline", [])]
        if len(cl) < MIN_POINTS:
            continue
        hw = half_width_m(r)
        pts = mg.with_cumulative(cl, mpd)
        prepared.append({
            "fid": fid,
            "points": pts,
            "total_length_m": pts[-1][2],
            "width_m": hw * 2.0,
            "half_width_m": hw,
            "road_type_sid": table.intern(r.get("road_type") or "trail"),
            "surface_sid": table.intern(r.get("surface")),
            "name_sid": table.intern(r.get("name")),
            "lanes": _int_or_none(r.get("lanes")),
        })

    levels = []
    counts = {"features": len(prepared), "records_per_level": {}}
    for nside in levels_ns:
        eps_deg = 0.0
        per_tile = {}
        for road in prepared:
            eps_m = mg.decim_eps_m(nside, radius_m, road["half_width_m"], res_max)
            eps_deg = eps_m / mpd
            for ipix, pieces in mg.partition_polyline(nside, road["points"]).items():
                for piece in pieces:
                    piece = mg.douglas_peucker(piece, eps_deg)
                    if len(piece) < MIN_POINTS:
                        continue
                    per_tile.setdefault(ipix, []).append(
                        dsmp.pack_road(
                            road["road_type_sid"], road["surface_sid"],
                            road["name_sid"], road["lanes"], road["width_m"],
                            road["total_length_m"], road["fid"], piece))
        tiles = []
        n_records = 0
        for ipix in sorted(per_tile):
            blocks = per_tile[ipix]
            n_records += len(blocks)
            tiles.append((ipix, dsmp.part_tile(len(blocks), b"".join(blocks))))
        levels.append((nside, tiles))
        counts["records_per_level"][str(nside)] = n_records
        if verbose:
            print("    n%-5d %5d tiles %6d pieces" % (nside, len(tiles), n_records))

    manifest = {
        "kind": "road",
        "max_nside": policy["max"],
        "min_nside": policy["min"],
        "levels": levels_ns,
        "export_nside": export_nside,
        "max_quadtree_nside": max_quadtree_nside,
        "radius": radius_m,
        "counts": counts,
        "assignment": "partition",
        "decimation": {"frac_of_vertex_spacing": 0.25,
                       "frac_of_influence": 0.5, "res_max": res_max},
    }
    return levels, manifest


def _int_or_none(v):
    if v is None:
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


# ── QGIS-side helpers (lazy import) ─────────────────────────────────────

def find_roads_layer(planet_name=None):
    """Exact name match first, then any line layer named like a road one."""
    from qgis.core import QgsProject, QgsVectorLayer, QgsWkbTypes

    layers = list(QgsProject.instance().mapLayers().values())
    wanted = ["roads"]
    if planet_name:
        wanted.append("%s_roads" % planet_name)
    for name in wanted:
        for l in layers:
            if l.name().lower() == name.lower() and isinstance(l, QgsVectorLayer):
                return l
    for l in layers:
        if isinstance(l, QgsVectorLayer) and "road" in l.name().lower() \
                and l.geometryType() == QgsWkbTypes.LineGeometry:
            return l
    return None


def line_parts(geom):
    """Every polyline of [geom] as its own list of QgsPointXY.

    Multipart roads are split into one feature per part rather than merged:
    concatenating disjoint parts would invent a straight segment joining them.
    """
    if geom is None or geom.isEmpty():
        return []
    if geom.isMultipart():
        return [part for part in geom.asMultiPolyline() if len(part) >= 2]
    line = geom.asPolyline()
    return [line] if len(line) >= 2 else []


def is_null(value):
    """True for a NULL attribute, whether PyQGIS returns None or a QVariant."""
    if value is None:
        return True
    if hasattr(value, "isNull"):
        return bool(value.isNull())
    return str(value) == "NULL"


def attr(feat, name):
    """Raw attribute value, or None when the field is absent or NULL."""
    if feat.fields().indexOf(name) < 0:
        return None
    value = feat[name]
    return None if is_null(value) else value


def feature_props(feat):
    """ROAD_FIELDS of [feat] as plain JSON-safe values."""
    props = {}
    for field in ROAD_FIELDS:
        value = attr(feat, field)
        if value is not None:
            props[field] = value if isinstance(value, (int, float, str)) \
                else str(value)
    return props
