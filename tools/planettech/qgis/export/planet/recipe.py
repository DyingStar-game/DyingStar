"""
export/planet/recipe.py
=======================
Generate per-chunk JSON recipe files for the DyingStar planet pipeline.

Public entry point::

    from export.planet.recipe import generate_chunk_recipes

    chunks_dir = generate_chunk_recipes(
        planet_name, planet_radius, export_dir,
        elev_min, elev_max,
        max_quadtree_depth, chunk_export_depth,
        find_layers_func, find_all_biome_layers_func,
        is_terrain_modifier_func, biome_index_for_type_func,
        ensure_dir_func, memlog_func, hpx,
    )

All module-level globals from ``export_planet.py`` are passed explicitly so
this module can be imported and tested in isolation.

Recipe binary format
--------------------
Each chunk is written as a gzip-compressed UTF-8 JSON blob (``<key>.recipe.bin``).
The QGIS export step produces the binary directly — no Godot headless conversion
step is required.  The Godot runtime reads entries via
``PlanetPack.read_entry_gzip_json()`` in ``planet_pack.gd``.
"""

import gzip
import json
import math
import os

import numpy as np

# Shared read-only state for multiprocessing workers (populated before fork).
# Workers inherit this dict via Linux copy-on-write — no serialisation cost.
_WORKER_STATE: dict = {}

# ---------------------------------------------------------------------------
# Crater physics constants — must stay in sync with export_planet.py and
# crater_terrain.gd in the Godot project.
# ---------------------------------------------------------------------------
_CR_RATIO_LARGE      = 0.20   # diameter > 400 m
_CR_RATIO_MEDIUM     = 0.17   # diameter 200–400 m
_CR_RATIO_SMALL      = 0.15   # diameter 100–200 m
_CR_RATIO_TINY       = 0.12   # diameter 30–100 m
_CR_RATIO_MICRO      = 0.10   # diameter < 30 m
_CR_MAX_DEPTH_M      = 500.0
_CR_MIN_RADIUS_M     = 20.0
_CR_RIM_UPLIFT_RATIO = 0.04
_CR_RIM_OUTER_MULT   = 1.15


def _crater_depth_for_radius(radius_m):
    """Compute crater depth from radius (metres).  Matches SpatialCraterTerrain.depth_for_radius."""
    diameter = radius_m * 2.0
    if diameter > 400.0:
        ratio = _CR_RATIO_LARGE
    elif diameter > 200.0:
        t = (diameter - 200.0) / 200.0
        ratio = _CR_RATIO_MEDIUM + (_CR_RATIO_LARGE - _CR_RATIO_MEDIUM) * t
    elif diameter > 100.0:
        t = (diameter - 100.0) / 100.0
        ratio = _CR_RATIO_SMALL + (_CR_RATIO_MEDIUM - _CR_RATIO_SMALL) * t
    elif diameter > 30.0:
        t = (diameter - 30.0) / 70.0
        ratio = _CR_RATIO_TINY + (_CR_RATIO_SMALL - _CR_RATIO_TINY) * t
    else:
        ratio = _CR_RATIO_MICRO
    return min(diameter * ratio, _CR_MAX_DEPTH_M)


# ---------------------------------------------------------------------------
# Pure geometry helpers (no external dependencies)
# ---------------------------------------------------------------------------

def _clip_polygon_to_chunk(poly_coords, lon_min, lon_max, lat_min, lat_max):
    """
    Clip a polygon (list of [lon, lat] vertices) to the chunk bounding box.

    Returns:
      "full"       — chunk is entirely inside the polygon
      None         — no intersection
      list of [lon, lat] — clipped polygon vertices (partial overlap)

    Uses Sutherland-Hodgman clipping against the 4 bbox edges.
    """
    if not poly_coords or len(poly_coords) < 3:
        return None

    # Quick AABB reject
    plons = [p[0] for p in poly_coords]
    plats = [p[1] for p in poly_coords]
    if max(plons) < lon_min or min(plons) > lon_max:
        return None
    if max(plats) < lat_min or min(plats) > lat_max:
        return None

    # Check if chunk is entirely inside polygon (all 4 corners inside)
    corners = [
        [lon_min, lat_min], [lon_max, lat_min],
        [lon_max, lat_max], [lon_min, lat_max],
    ]
    all_inside = all(
        _point_in_polygon(c[0], c[1], poly_coords) for c in corners
    )
    if all_inside:
        return "full"

    # Sutherland-Hodgman clipping
    output = list(poly_coords)
    edges = [
        ("left",   lon_min, None),
        ("right",  lon_max, None),
        ("bottom", None,    lat_min),
        ("top",    None,    lat_max),
    ]
    for edge_type, val_lon, val_lat in edges:
        if not output:
            return None
        clipped = []
        for i in range(len(output)):
            curr = output[i]
            prev = output[i - 1]
            curr_inside = _inside_edge(curr, edge_type, val_lon, val_lat)
            prev_inside = _inside_edge(prev, edge_type, val_lon, val_lat)
            if curr_inside:
                if not prev_inside:
                    clipped.append(_intersect_edge(prev, curr, edge_type, val_lon, val_lat))
                clipped.append(curr)
            elif prev_inside:
                clipped.append(_intersect_edge(prev, curr, edge_type, val_lon, val_lat))
        output = clipped

    if len(output) < 3:
        return None

    # Round the output vertices
    return [[round(p[0], 6), round(p[1], 6)] for p in output]


def _inside_edge(point, edge_type, val_lon, val_lat):
    """Check if a point is inside a clipping edge."""
    if edge_type == "left":
        return point[0] >= val_lon
    elif edge_type == "right":
        return point[0] <= val_lon
    elif edge_type == "bottom":
        return point[1] >= val_lat
    elif edge_type == "top":
        return point[1] <= val_lat
    return True


def _intersect_edge(p1, p2, edge_type, val_lon, val_lat):
    """Compute intersection point of segment p1→p2 with a clipping edge."""
    dx = p2[0] - p1[0]
    dy = p2[1] - p1[1]
    if edge_type in ("left", "right"):
        if abs(dx) < 1e-12:
            return [val_lon, p1[1]]
        t = (val_lon - p1[0]) / dx
        return [val_lon, p1[1] + t * dy]
    else:
        if abs(dy) < 1e-12:
            return [p1[0], val_lat]
        t = (val_lat - p1[1]) / dy
        return [p1[0] + t * dx, val_lat]


def _point_in_polygon(x, y, poly):
    """Ray-casting point-in-polygon test."""
    n = len(poly)
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = poly[i][0], poly[i][1]
        xj, yj = poly[j][0], poly[j][1]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def _simplify_polygon(coords, tolerance=0.0001):
    """
    Douglas-Peucker simplification for a polygon ring.
    tolerance is in degrees (~11m at equator for 0.0001).
    """
    if len(coords) <= 4:
        return coords

    def _dp(points, start, end, tol):
        max_dist = 0.0
        max_idx = start
        for i in range(start + 1, end):
            d = _point_line_dist(points[i], points[start], points[end])
            if d > max_dist:
                max_dist = d
                max_idx = i
        if max_dist > tol:
            left = _dp(points, start, max_idx, tol)
            right = _dp(points, max_idx, end, tol)
            return left[:-1] + right
        return [points[start], points[end]]

    def _point_line_dist(p, a, b):
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        if dx == 0 and dy == 0:
            return math.sqrt((p[0] - a[0]) ** 2 + (p[1] - a[1]) ** 2)
        t = max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)))
        proj_x = a[0] + t * dx
        proj_y = a[1] + t * dy
        return math.sqrt((p[0] - proj_x) ** 2 + (p[1] - proj_y) ** 2)

    result = _dp(coords, 0, len(coords) - 1, tolerance)
    return result if len(result) >= 3 else coords


# ---------------------------------------------------------------------------
# Populate-data collection (needs QGIS callback functions)
# ---------------------------------------------------------------------------

def _collect_populate_data(find_all_biome_layers_func, is_terrain_modifier_func,
                            biome_index_for_type_func):
    """
    Collect all populate-only biome features from QGIS layers.

    Parameters
    ----------
    find_all_biome_layers_func : callable
        ``find_all_biome_layers()`` from export_planet.py — returns
        ``{"polygon": [...], "line": [...], "point": [...]}``
    is_terrain_modifier_func : callable
        ``_is_terrain_modifier(btype)`` from export_planet.py
    biome_index_for_type_func : callable
        ``_biome_index_for_type(btype)`` from export_planet.py

    Returns
    -------
    polygon_zones : list of dict
        ``{"biome_type", "biome_index", "coords": [[lon, lat], ...], "props": {}}``
    point_zones : list of dict
        ``{"biome_type", "biome_index", "lon", "lat", "props": {}}``
    """
    biome_layers = find_all_biome_layers_func()
    polygon_zones = []
    point_zones = []

    # ── Polygon populate biomes ──
    for layer in biome_layers["polygon"]:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        if not has_btype:
            continue
        # Collect property field names (density, canopy_height, etc.)
        prop_fields = []
        for field in layer.fields():
            fname = field.name().lower()
            if fname not in ("biome_type", "fid", "id") and not fname.startswith("_"):
                prop_fields.append(field.name())

        for feat in layer.getFeatures():
            btype = str(feat["biome_type"]) if feat["biome_type"] else ""
            if not btype or is_terrain_modifier_func(btype):
                continue  # skip terrain modifiers — already in recipes
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            bindex = biome_index_for_type_func(btype)

            # Collect properties
            props = {}
            for fname in prop_fields:
                val = feat[fname]
                if val is not None:
                    try:
                        props[fname] = float(val) if isinstance(val, (int, float)) else str(val)
                    except (ValueError, TypeError):
                        props[fname] = str(val)

            # Extract polygon rings
            if geom.isMultipart():
                for part in geom.asMultiPolygon():
                    if part and part[0]:
                        coords = [[round(p.x(), 6), round(p.y(), 6)] for p in part[0]]
                        if len(coords) >= 3:
                            polygon_zones.append({
                                "biome_type": btype,
                                "biome_index": bindex,
                                "coords": coords,
                                "props": props,
                            })
            else:
                rings = geom.asPolygon()
                if rings and rings[0]:
                    coords = [[round(p.x(), 6), round(p.y(), 6)] for p in rings[0]]
                    if len(coords) >= 3:
                        polygon_zones.append({
                            "biome_type": btype,
                            "biome_index": bindex,
                            "coords": coords,
                            "props": props,
                        })

    # ── Point populate biomes ──
    for layer in biome_layers["point"]:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        if not has_btype:
            continue
        prop_fields = []
        for field in layer.fields():
            fname = field.name().lower()
            if fname not in ("biome_type", "fid", "id", "radius", "depth") and not fname.startswith("_"):
                prop_fields.append(field.name())

        for feat in layer.getFeatures():
            btype = str(feat["biome_type"]) if feat["biome_type"] else ""
            if not btype or is_terrain_modifier_func(btype):
                continue  # skip terrain modifiers
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            pt = geom.asPoint()
            bindex = biome_index_for_type_func(btype)
            props = {}
            for fname in prop_fields:
                val = feat[fname]
                if val is not None:
                    try:
                        props[fname] = float(val) if isinstance(val, (int, float)) else str(val)
                    except (ValueError, TypeError):
                        props[fname] = str(val)
            point_zones.append({
                "biome_type": btype,
                "biome_index": bindex,
                "lon": round(pt.x(), 6),
                "lat": round(pt.y(), 6),
                "props": props,
            })

    print(f"  Collected {len(polygon_zones)} populate polygon zones, "
          f"{len(point_zones)} populate point zones")
    return polygon_zones, point_zones


def _build_populate_zones_for_chunk(lon_min, lon_max, lat_min, lat_max,
                                     polygon_zones, point_zones,
                                     polygon_spatial_idx=None):
    """
    Build the populate_zones array for a single chunk.

    For each populate polygon: clip to chunk bbox, classify as full/partial/None.
    For each populate point: check if inside chunk bbox.

    Returns list of zone dicts ready for recipe JSON.
    """
    zones = []

    # Polygon zones — check spatial index if available, else brute force bbox
    if polygon_spatial_idx is not None:
        candidates = polygon_spatial_idx(lon_min, lon_max, lat_min, lat_max)
    else:
        candidates = range(len(polygon_zones))

    for idx in candidates:
        pz = polygon_zones[idx]
        result = _clip_polygon_to_chunk(pz["coords"], lon_min, lon_max, lat_min, lat_max)
        if result is None:
            continue
        zone = {
            "biome_type": pz["biome_type"],
            "biome_index": pz["biome_index"],
        }
        if result == "full":
            zone["coverage"] = "full"
        else:
            clipped = _simplify_polygon(result)
            zone["coverage"] = "partial"
            zone["vertices"] = clipped
        # Merge any biome-specific properties
        if pz["props"]:
            zone.update(pz["props"])
        zones.append(zone)

    # Point zones
    for pz in point_zones:
        if lon_min <= pz["lon"] <= lon_max and lat_min <= pz["lat"] <= lat_max:
            zone = {
                "biome_type": pz["biome_type"],
                "biome_index": pz["biome_index"],
                "coverage": "point",
                "lon": pz["lon"],
                "lat": pz["lat"],
            }
            if pz["props"]:
                zone.update(pz["props"])
            zones.append(zone)

    return zones


# ---------------------------------------------------------------------------
# Contour polyline clipping helper
# ---------------------------------------------------------------------------

def _clip_polyline_to_bbox(pts, lon_min, lon_max, lat_min, lat_max):
    """
    Clip a polyline (Nx2 numpy float32 array) to a bounding box.

    Uses Liang-Barsky clipping per segment.  Returns a list of sub-polylines
    (each an Mx2 numpy float32 array with M >= 2).  Consecutive segments that
    share an endpoint are kept in the same sub-polyline; a gap anywhere in the
    clip window starts a fresh one.
    """
    if len(pts) < 2:
        return []

    def _lb(x0, y0, x1, y1):
        """Liang-Barsky: returns (t0, t1) or None if fully outside."""
        dx, dy = x1 - x0, y1 - y0
        t0, t1 = 0.0, 1.0
        for p, q in [(-dx, x0 - lon_min), (dx, lon_max - x0),
                     (-dy, y0 - lat_min), (dy, lat_max - y0)]:
            if p == 0.0:
                if q < 0.0:
                    return None
            elif p < 0.0:
                t0 = max(t0, q / p)
            else:
                t1 = min(t1, q / p)
            if t0 > t1:
                return None
        return t0, t1

    result = []
    current = []  # accumulating sub-polyline as list of [x, y]

    for i in range(len(pts) - 1):
        x0, y0 = float(pts[i, 0]), float(pts[i, 1])
        x1, y1 = float(pts[i + 1, 0]), float(pts[i + 1, 1])
        clip = _lb(x0, y0, x1, y1)
        if clip is None:
            # Segment entirely outside — close any open sub-polyline.
            if current:
                result.append(np.array(current, dtype=np.float32))
                current = []
            continue
        t0, t1 = clip
        px0 = x0 + t0 * (x1 - x0)
        py0 = y0 + t0 * (y1 - y0)
        px1 = x0 + t1 * (x1 - x0)
        py1 = y0 + t1 * (y1 - y0)
        if not current:
            current.append([px0, py0])
        elif t0 > 1e-9:
            # Segment was clipped at its start — previous endpoint and this
            # entry point are different → close current and start fresh.
            result.append(np.array(current, dtype=np.float32))
            current = [[px0, py0]]
        current.append([px1, py1])
        if t1 < 1.0 - 1e-9:
            # Segment was clipped at its end — close and let the next
            # visible segment open a new sub-polyline.
            result.append(np.array(current, dtype=np.float32))
            current = []

    if current:
        result.append(np.array(current, dtype=np.float32))

    return [s for s in result if len(s) >= 2]


# ---------------------------------------------------------------------------
# Per-pixel worker (called by multiprocessing pool via fork)
# ---------------------------------------------------------------------------

def _process_pixel(ipix: int) -> dict:
    """Build and write one chunk recipe JSON; return its manifest entry."""
    W                  = _WORKER_STATE
    contour_features   = W["contour_features"]
    contour_bboxes     = W["contour_bboxes"]
    crater_arr         = W["crater_arr"]
    crater_tree        = W["crater_tree"]
    linear_features    = W["linear_features"]
    radial_features    = W["radial_features"]
    populate_polygons  = W["populate_polygons"]
    populate_points    = W["populate_points"]
    poly_bboxes        = W["poly_bboxes"]
    noise_config       = W["noise_config"]
    chunks_dir         = W["chunks_dir"]
    export_dir         = W["export_dir"]
    nside              = W["nside"]
    _elev_min          = W["elev_min"]
    m_per_deg          = W["m_per_deg"]
    _chunk_side_deg    = W["chunk_side_deg"]
    MARGIN_DEG         = W["MARGIN_DEG"]
    max_crater_outer_deg = W["max_crater_outer_deg"]
    hpx                = W["hpx"]

    base_pixel = ipix // (nside * nside)
    base_dir   = os.path.join(chunks_dir, f"base_{base_pixel}")
    # Directories are pre-created by the parent process.

    lon_min_c, lon_max_c, lat_min_c, lat_max_c = \
        hpx.get_tile_lonlat_bbox(nside, ipix, margin_deg=0.0)
    safe_span   = _chunk_side_deg * 2.0
    center_lon  = (lon_min_c + lon_max_c) / 2.0
    center_lat  = (lat_min_c + lat_max_c) / 2.0

    # ── Query nearby contour segments (vectorised AABB) ──
    clip_lon_min = lon_min_c - MARGIN_DEG
    clip_lon_max = lon_max_c + MARGIN_DEG
    clip_lat_min = lat_min_c - MARGIN_DEG
    clip_lat_max = lat_max_c + MARGIN_DEG

    chunk_segments = []
    if len(contour_bboxes) > 0:
        overlap = (
            (contour_bboxes[:, 1] >= clip_lon_min) &
            (contour_bboxes[:, 0] <= clip_lon_max) &
            (contour_bboxes[:, 3] >= clip_lat_min) &
            (contour_bboxes[:, 2] <= clip_lat_max)
        )
        for idx in np.where(overlap)[0]:
            elev_c, pts = contour_features[idx]
            sub_lines = _clip_polyline_to_bbox(
                pts, clip_lon_min, clip_lon_max, clip_lat_min, clip_lat_max)
            for sub in sub_lines:
                chunk_segments.append({
                    "elev": round(float(elev_c), 2),
                    "pts": np.round(sub, 6).tolist(),
                })

    if chunk_segments:
        base_elev = round(float(np.median([s["elev"] for s in chunk_segments])), 2)
    else:
        base_elev = round(float(_elev_min), 2)

    # ── Query nearby craters ──
    chunk_craters = []
    if crater_tree is not None and len(crater_arr) > 0:
        search_r = safe_span + max_crater_outer_deg
        nearby_cr = crater_tree.query_ball_point([center_lon, center_lat], search_r)
        for idx in nearby_cr:
            cr_lon_v    = float(crater_arr[idx, 0])
            cr_lat_v    = float(crater_arr[idx, 1])
            cr_radius_v = float(crater_arr[idx, 2])
            cr_depth_v  = float(crater_arr[idx, 3])
            cr_outer_deg_lat = cr_radius_v * _CR_RIM_OUTER_MULT / m_per_deg
            _cos_c = math.cos(math.radians(cr_lat_v)) if abs(cr_lat_v) < 89.5 else 0.01
            cr_outer_deg_lon = cr_outer_deg_lat / _cos_c
            if (lon_max_c + cr_outer_deg_lon >= cr_lon_v - cr_outer_deg_lon and
                    lon_min_c - cr_outer_deg_lon <= cr_lon_v + cr_outer_deg_lon and
                    lat_max_c + cr_outer_deg_lat >= cr_lat_v - cr_outer_deg_lat and
                    lat_min_c - cr_outer_deg_lat <= cr_lat_v + cr_outer_deg_lat):
                chunk_craters.append({
                    "lon": round(cr_lon_v, 6),
                    "lat": round(cr_lat_v, 6),
                    "radius_m": round(cr_radius_v, 1),
                    "depth_m": round(cr_depth_v, 2),
                })
    elif len(crater_arr) > 0:
        for ci in range(len(crater_arr)):
            cr_lon_v    = float(crater_arr[ci, 0])
            cr_lat_v    = float(crater_arr[ci, 1])
            cr_radius_v = float(crater_arr[ci, 2])
            cr_depth_v  = float(crater_arr[ci, 3])
            cr_outer_deg_lat = cr_radius_v * _CR_RIM_OUTER_MULT / m_per_deg
            _cos_c = math.cos(math.radians(cr_lat_v)) if abs(cr_lat_v) < 89.5 else 0.01
            cr_outer_deg_lon = cr_outer_deg_lat / _cos_c
            if (lon_max_c + cr_outer_deg_lon >= cr_lon_v - cr_outer_deg_lon and
                    lon_min_c - cr_outer_deg_lon <= cr_lon_v + cr_outer_deg_lon and
                    lat_max_c + cr_outer_deg_lat >= cr_lat_v - cr_outer_deg_lat and
                    lat_min_c - cr_outer_deg_lat <= cr_lat_v + cr_outer_deg_lat):
                chunk_craters.append({
                    "lon": round(cr_lon_v, 6),
                    "lat": round(cr_lat_v, 6),
                    "radius_m": round(cr_radius_v, 1),
                    "depth_m": round(cr_depth_v, 2),
                })

    # ── Query overlapping linear features ──
    chunk_linear = []
    margin_lin = 0.5  # extra degrees margin for linear feature overlap
    for lf in linear_features:
        bb = lf["bbox_min"]
        bt = lf["bbox_max"]
        if (lon_max_c + margin_lin >= bb[0] and
                lon_min_c - margin_lin <= bt[0] and
                lat_max_c + margin_lin >= bb[1] and
                lat_min_c - margin_lin <= bt[1]):
            entry = {
                "type": lf["type"],
                "centerline": lf["centerline"],
                "width_start_m": lf["width_start_m"],
                "width_end_m": lf["width_end_m"],
                "half_width_max_deg": lf["half_width_max_deg"],
                "total_length_m": lf["total_length_m"],
                "cum_lengths": lf["cum_lengths"],
                "profile": lf["profile"],
            }
            if lf["depth_override"] is not None:
                entry["depth_override"] = lf["depth_override"]
            chunk_linear.append(entry)

    # ── Query overlapping radial features ──
    chunk_radial = []
    for rf in radial_features:
        rf_outer_deg = rf["radius_m"] * 1.5 / m_per_deg
        if (lon_max_c + rf_outer_deg >= rf["lon"] - rf_outer_deg and
                lon_min_c - rf_outer_deg <= rf["lon"] + rf_outer_deg and
                lat_max_c + rf_outer_deg >= rf["lat"] - rf_outer_deg and
                lat_min_c - rf_outer_deg <= rf["lat"] + rf_outer_deg):
            chunk_radial.append(rf)

    # ── Deterministic noise seed ──
    noise_seed = ipix * 104729 + nside * 7919

    # ── Build populate zones ──
    def _poly_spatial_query(lon_min, lon_max, lat_min, lat_max):
        result = []
        for pmin_lon, pmax_lon, pmin_lat, pmax_lat, idx in poly_bboxes:
            if (pmax_lon >= lon_min and pmin_lon <= lon_max and
                    pmax_lat >= lat_min and pmin_lat <= lat_max):
                result.append(idx)
        return result

    chunk_populate = _build_populate_zones_for_chunk(
        lon_min_c, lon_max_c, lat_min_c, lat_max_c,
        populate_polygons, populate_points,
        polygon_spatial_idx=_poly_spatial_query,
    )

    # ── Build recipe ──
    chunk_key = f"hp_n{nside}_p{ipix}"
    recipe = {
        "version": 7,
        "key": chunk_key,
        "nside": nside,
        "ipix": ipix,
        "elevation": {
            "base_elevation": base_elev,
            "interpolation": "contour_segment_idw",
            "idw_power": 2,
            "idw_k": 8,
            "contour_segments": chunk_segments,
        },
        "terrain_modifiers": {
            "craters": chunk_craters,
            "linear_features": chunk_linear,
            "radial_features": chunk_radial,
        },
        "populate_zones": chunk_populate,
        "noise": {
            "seed": noise_seed,
            "octaves": noise_config["octaves"],
        },
    }
    # Backwards compat flat keys
    recipe["craters"] = chunk_craters
    recipe["linear_features"] = chunk_linear
    recipe["radial_features"] = chunk_radial

    # ── Save recipe as gzip-compressed JSON binary ──
    json_bytes = json.dumps(recipe, separators=(',', ':')).encode('utf-8')
    out_path = os.path.join(base_dir, f"{chunk_key}.recipe.bin")
    with open(out_path, "wb") as f:
        f.write(gzip.compress(json_bytes, compresslevel=6))

    return {
        "key": chunk_key,
        "nside": nside,
        "ipix": ipix,
        "file": os.path.relpath(out_path, export_dir),
        "segment_count": len(chunk_segments),
        "crater_count": len(chunk_craters),
        "linear_count": len(chunk_linear),
        "radial_count": len(chunk_radial),
        "populate_zone_count": len(chunk_populate),
    }


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def generate_chunk_recipes(
    planet_name,
    planet_radius,
    export_dir,
    elev_min,
    elev_max,
    max_quadtree_depth,
    chunk_export_depth,
    find_layers_func,
    find_all_biome_layers_func,
    is_terrain_modifier_func,
    biome_index_for_type_func,
    ensure_dir_func,
    memlog_func,
    hpx,
):
    """
    Export per-chunk JSON recipe files instead of pre-baked PNG heightmaps.

    Each recipe embeds clipped contour polyline segments for the chunk area.
    Godot reconstructs elevation at runtime via per-segment IDW (power=2,
    k=8 nearest segments weighted by minimum point-to-segment distance).
    Also includes crater data, linear features (rivers/canyons), radial
    features (fumaroles/caves/volcanoes), populate zones, and noise parameters.
    No global GeoTIFF heightmap is required.

    Parameters
    ----------
    planet_name : str
    planet_radius : float
        Planet radius in metres.
    export_dir : str
        Root directory for export output.
    elev_min : float or None
        Minimum elevation (metres); ``None`` → derived from contours.
    elev_max : float or None
        Maximum elevation (metres); ``None`` → derived from contours.
    max_quadtree_depth : int
    chunk_export_depth : int
    find_layers_func : callable
        ``find_layers_by_keyword(keyword)`` from export_planet.py.
    find_all_biome_layers_func : callable
        ``find_all_biome_layers()`` from export_planet.py.
    is_terrain_modifier_func : callable
        ``_is_terrain_modifier(btype)`` from export_planet.py.
    biome_index_for_type_func : callable
        ``_biome_index_for_type(btype)`` from export_planet.py.
    ensure_dir_func : callable
        ``ensure_dir(path)`` from export_planet.py.
    memlog_func : callable
        ``memlog(label, detail="")`` from export_planet.py.
    hpx : module
        Loaded ``healpix_utils`` module (provides ``get_tile_lonlat_bbox``,
        ``nest2xy``, ``face_xy_to_lonlat``).

    Returns
    -------
    str
        Path to the ``*_chunks`` directory that was written.
    """
    import time as _time

    try:
        from qgis.core import QgsVectorLayer
    except ImportError:
        QgsVectorLayer = None

    memlog_func("chunk_recipes: START")

    # ── 1. Collect contour polylines ──
    contour_layers = find_layers_func("contour") + find_layers_func("elevation")
    if QgsVectorLayer is not None:
        vector_layers = [l for l in contour_layers if isinstance(l, QgsVectorLayer)]
    else:
        vector_layers = contour_layers

    contour_features = []  # list of (elev: float, pts: np.float32 Nx2)
    _bbox_list = []        # list of [lon_min, lon_max, lat_min, lat_max]
    _elev_all = []         # for global min/max derivation
    elev_field_name = None
    for layer in vector_layers:
        elev_field = None
        for field in layer.fields():
            if field.name().lower() in ("elev", "elevation", "height", "z", "alt"):
                elev_field = field.name()
                break
        if not elev_field:
            continue
        elev_field_name = elev_field
        for feature in layer.getFeatures():
            elev = feature[elev_field]
            if elev is None:
                continue
            elev = float(elev)
            geom = feature.geometry()
            if geom is None or geom.isNull():
                continue
            pts = np.array([[v.x(), v.y()] for v in geom.vertices()], dtype=np.float32)
            if len(pts) < 2:
                continue
            # Skip null-island artifacts
            cx, cy = float(pts[:, 0].mean()), float(pts[:, 1].mean())
            if abs(cx) < 0.01 and abs(cy) < 0.01 and elev == 0.0:
                continue
            contour_features.append((elev, pts))
            _bbox_list.append([float(pts[:, 0].min()), float(pts[:, 0].max()),
                                float(pts[:, 1].min()), float(pts[:, 1].max())])
            _elev_all.append(elev)

    if contour_features:
        contour_bboxes = np.array(_bbox_list, dtype=np.float32)
        _elev_arr = np.array(_elev_all, dtype=np.float32)
        memlog_func("chunk_recipes: contour polylines built",
                    f"lines={len(contour_features)}, "
                    f"elev_range=[{_elev_arr.min():.1f},{_elev_arr.max():.1f}]")
        print(f"  {len(contour_features)} contour polylines, elevation range "
              f"[{_elev_arr.min():.1f}, {_elev_arr.max():.1f}]m")
        del _elev_arr
    else:
        contour_bboxes = np.empty((0, 4), dtype=np.float32)
        print("  ⚠ No contour polylines found — recipes will have flat base elevation.")
    del _bbox_list, _elev_all

    # ── 2. Collect crater data ──
    point_layers = find_all_biome_layers_func()["point"]

    # Use 4 parallel float lists instead of a list of dicts — saves ~1.5 GB
    # for dense crater datasets (e.g. 6M craters).  The lists are converted
    # to a compact numpy array once collection is complete.
    _cr_lons = []
    _cr_lats = []
    _cr_radii = []
    _cr_depths = []
    radial_features = []  # fumaroles, caves, volcanoes, etc.
    m_per_deg = planet_radius * math.pi / 180.0

    for layer in point_layers:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        has_radius = layer.fields().indexOf("radius") >= 0
        has_depth = layer.fields().indexOf("depth") >= 0
        # Individual biome layers store biome_type as a layer custom property
        # instead of a per-feature field.
        layer_btype = layer.customProperty("biome_type", "")
        if not has_btype and not layer_btype:
            continue
        for feat in layer.getFeatures():
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            pt = geom.asPoint()
            if has_btype and feat["biome_type"]:
                btype = str(feat["biome_type"])
            else:
                btype = layer_btype

            if btype == "spatial-crater":
                radius_m = 185.0
                if has_radius and feat["radius"] is not None:
                    try:
                        r = float(feat["radius"])
                        if r > 0:
                            radius_m = r
                    except (ValueError, TypeError):
                        pass
                if radius_m < _CR_MIN_RADIUS_M:
                    continue
                depth_m = _crater_depth_for_radius(radius_m)
                _cr_lons.append(round(pt.x(), 6))
                _cr_lats.append(round(pt.y(), 6))
                _cr_radii.append(round(radius_m, 1))
                _cr_depths.append(round(depth_m, 2))
            elif btype in ("volcanic_geothermal-fumarole", "fumarole", "cave", "volcanic_geothermal-active_volcano",
                           "volcanic_active", "volcanic_geothermal-ice_geyser", "ice_geyser",
                           "volcanic_geothermal-mineral_thermal_source", "mineral_hot_spring"):
                radius_m = 185.0
                if has_radius and feat["radius"] is not None:
                    try:
                        r = float(feat["radius"])
                        if r > 0:
                            radius_m = r
                    except (ValueError, TypeError):
                        pass
                depth_m = 15.0  # default
                if has_depth and feat["depth"] is not None:
                    try:
                        d = float(feat["depth"])
                        if d > 0:
                            depth_m = d
                    except (ValueError, TypeError):
                        pass
                profile = "bowl"
                if btype in ("volcanic_geothermal-active_volcano", "volcanic_active"):
                    profile = "volcanic"
                radial_features.append({
                    "type": btype,
                    "lon": round(pt.x(), 6),
                    "lat": round(pt.y(), 6),
                    "radius_m": round(radius_m, 1),
                    "depth_m": round(depth_m, 2),
                    "profile": profile,
                })

    # Convert to compact numpy float64 array: (N, 4) columns = lon, lat, radius_m, depth_m.
    # Free the primitive lists immediately to reclaim memory before KDTree construction.
    _crater_count = len(_cr_lons)
    print(f"  {_crater_count} craters, {len(radial_features)} radial features")
    memlog_func("chunk_recipes: craters collected", f"count={_crater_count}")
    if _crater_count > 0:
        crater_arr = np.array([_cr_lons, _cr_lats, _cr_radii, _cr_depths], dtype=np.float64).T
        # Deduplicate craters that appear in multiple QGIS layers
        _pre_dedup = len(crater_arr)
        crater_arr = np.unique(crater_arr, axis=0)
        if len(crater_arr) < _pre_dedup:
            print(f"  Removed {_pre_dedup - len(crater_arr)} duplicate craters "
                  f"({len(crater_arr)} unique)")
    else:
        crater_arr = np.empty((0, 4), dtype=np.float64)
    del _cr_lons, _cr_lats, _cr_radii, _cr_depths

    # ── 3. Collect linear features (rivers, canyons, lava rivers, etc.) ──
    linear_features = []
    biome_layers = find_all_biome_layers_func()
    for layer in biome_layers["line"]:
        has_btype = layer.fields().indexOf("biome_type") >= 0
        has_ws = layer.fields().indexOf("width_start") >= 0
        has_we = layer.fields().indexOf("width_end") >= 0
        has_width = layer.fields().indexOf("width") >= 0
        has_depth = layer.fields().indexOf("depth") >= 0
        for feat in layer.getFeatures():
            geom = feat.geometry()
            if geom is None or geom.isEmpty():
                continue
            btype = str(feat["biome_type"]) if has_btype and feat["biome_type"] else "maritime_river-river"

            # Extract centerline
            centerline = []
            if geom.isMultipart():
                for part in geom.asMultiPolyline():
                    for pt in part:
                        centerline.append([round(pt.x(), 6), round(pt.y(), 6)])
            else:
                for pt in geom.asPolyline():
                    centerline.append([round(pt.x(), 6), round(pt.y(), 6)])
            if len(centerline) < 2:
                continue

            # Read progressive width (metres)
            width_start_m = 0.0
            width_end_m = 0.0
            if has_ws and feat["width_start"] is not None:
                try:
                    ws = float(feat["width_start"])
                    if ws > 0:
                        width_start_m = ws
                except (ValueError, TypeError):
                    pass
            if has_we and feat["width_end"] is not None:
                try:
                    we = float(feat["width_end"])
                    if we > 0:
                        width_end_m = we
                except (ValueError, TypeError):
                    pass
            # Legacy fallback: single 'width' field
            if width_start_m <= 0.0 and width_end_m <= 0.0 and has_width:
                if feat["width"] is not None:
                    try:
                        w = float(feat["width"])
                        if w > 0:
                            width_start_m = w
                            width_end_m = w
                    except (ValueError, TypeError):
                        pass
            if width_start_m <= 0.0 and width_end_m <= 0.0:
                width_start_m = 100.0
                width_end_m = 100.0

            # Skip degenerate rivers where both widths are effectively zero
            if max(width_start_m, width_end_m) < 0.01:
                continue

            # Depth: override from 'depth' field, or derive from width (1:10 ratio)
            depth_override = None
            if has_depth and feat["depth"] is not None:
                try:
                    d = float(feat["depth"])
                    if d > 0:
                        depth_override = d
                except (ValueError, TypeError):
                    pass

            max_width_m = max(width_start_m, width_end_m)
            half_width_max_deg = (max_width_m / 2.0) / m_per_deg

            # Compute per-segment cumulative lengths for along_t calculation.
            # This allows the runtime to compute normalized position along
            # the centerline for width interpolation.
            seg_lengths = []
            for i in range(len(centerline) - 1):
                dx = (centerline[i + 1][0] - centerline[i][0]) * m_per_deg
                dy = (centerline[i + 1][1] - centerline[i][1]) * m_per_deg
                seg_lengths.append(round(math.sqrt(dx * dx + dy * dy), 2))
            total_length = sum(seg_lengths)
            cum_lengths = [0.0]
            running = 0.0
            for sl in seg_lengths:
                running += sl
                cum_lengths.append(round(running, 2))

            # Determine profile type
            profile = "v_shape"
            if btype in ("rocky_landform-canyon", "canyon", "icy-ice_crevasse", "ice_crevasse",
                         "aride_desert-dry_river_bed", "dry_riverbed", "rocky_landform-pressure_canyon",
                         "pressure_canyon"):
                profile = "u_shape"
            elif btype in ("volcanic_geothermal-lava_river", "lava_river"):
                profile = "u_shape"

            # Compute bounding box of this feature
            lons = [p[0] for p in centerline]
            lats = [p[1] for p in centerline]
            linear_features.append({
                "type": btype,
                "centerline": centerline,
                "width_start_m": round(width_start_m, 3),
                "width_end_m": round(width_end_m, 3),
                "half_width_max_deg": round(half_width_max_deg, 8),
                "depth_override": round(depth_override, 2) if depth_override is not None else None,
                "total_length_m": round(total_length, 2),
                "cum_lengths": cum_lengths,
                "profile": profile,
                "bbox_min": [min(lons) - half_width_max_deg, min(lats) - half_width_max_deg],
                "bbox_max": [max(lons) + half_width_max_deg, max(lats) + half_width_max_deg],
            })

    print(f"  {len(linear_features)} linear features")
    memlog_func("chunk_recipes: linear features collected",
                f"count={len(linear_features)}")

    # ── 3b. Collect populate-only biome data ──
    populate_polygons, populate_points = _collect_populate_data(
        find_all_biome_layers_func, is_terrain_modifier_func, biome_index_for_type_func
    )
    memlog_func("chunk_recipes: populate data collected",
                f"polygons={len(populate_polygons)}, points={len(populate_points)}")

    # Build a simple AABB spatial index for populate polygons
    # Each entry: (min_lon, max_lon, min_lat, max_lat, original_index)
    _poly_bboxes = []
    for i, pz in enumerate(populate_polygons):
        coords = pz["coords"]
        lons = [c[0] for c in coords]
        lats = [c[1] for c in coords]
        _poly_bboxes.append((min(lons), max(lons), min(lats), max(lats), i))

    def _polygon_spatial_query(lon_min, lon_max, lat_min, lat_max):
        """Return indices of populate polygons whose AABB overlaps the chunk bbox."""
        result = []
        for pmin_lon, pmax_lon, pmin_lat, pmax_lat, idx in _poly_bboxes:
            if pmax_lon >= lon_min and pmin_lon <= lon_max and \
               pmax_lat >= lat_min and pmin_lat <= lat_max:
                result.append(idx)
        return result

    # ── 4. Build spatial indices ──
    try:
        from scipy.spatial import cKDTree
        has_scipy = True
    except ImportError:
        has_scipy = False

    crater_tree = None
    max_crater_outer_deg = 0.0
    if len(crater_arr) > 0:
        max_crater_outer_deg = float(crater_arr[:, 2].max()) * _CR_RIM_OUTER_MULT / m_per_deg
        if has_scipy:
            crater_tree = cKDTree(crater_arr[:, :2])
            print(f"  Built crater KD-tree over {len(crater_arr)} craters")
            memlog_func("chunk_recipes: crater KD-tree built")

    # ── 5. Export configuration ──
    export_depth = min(max_quadtree_depth, chunk_export_depth)
    nside = 2 ** export_depth
    npix = 12 * nside * nside

    chunks_dir = os.path.join(export_dir, f"{planet_name}_chunks")
    ensure_dir_func(chunks_dir)

    _elev_min = elev_min if elev_min is not None else 0.0
    _elev_max = elev_max if elev_max is not None else 0.0
    if _elev_max <= _elev_min and contour_features:
        _all_elevs = np.array([e for e, _ in contour_features], dtype=np.float32)
        _elev_max = float(_all_elevs.max())
        _elev_min = float(_all_elevs.min())
        del _all_elevs
    elev_range = _elev_max - _elev_min if _elev_max > _elev_min else 1.0  # noqa: F841

    # Contour search margin: ~1× chunk angular width.
    # At depth 6, chunk ≈ 0.9°, so margin ≈ 0.9° is plenty for IDW overlap.
    # The grid samples from the global heightmap fill the interior anyway.
    _chunk_side_deg = math.degrees(math.sqrt(math.pi / 3.0) / nside)
    MARGIN_DEG = _chunk_side_deg * 1.0

    chunk_manifest = []
    total = npix
    count = 0

    # Global noise config — deterministic per chunk via seed
    noise_config = {
        "octaves": [
            {"frequency": 0.02, "amplitude": 2.0},
            {"frequency": 0.005, "amplitude": 8.0},
            {"frequency": 0.001, "amplitude": 20.0},
        ]
    }

    # ── 6. Pre-loop setup ──
    # Each chunk clips nearby contour polylines to its expanded bbox and
    # stores the segments directly in the recipe for Godot-side IDW.
    print(f"  Generating {total} chunk recipes (HEALPix nside={nside}, "
          f"{len(contour_features)} contour lines)...")
    memlog_func("chunk_recipes: entering main loop",
                f"total={total}, contour_lines={len(contour_features)}, "
                f"craters={len(crater_arr)}, linear={len(linear_features)}")

    # Pre-create all 12 base_* directories before workers start.
    for _b in range(12):
        ensure_dir_func(os.path.join(chunks_dir, f"base_{_b}"))

    # Populate shared worker state — inherited by forked workers via COW.
    import multiprocessing as _mp
    _WORKER_STATE.update({
        "contour_features":     contour_features,
        "contour_bboxes":       contour_bboxes,
        "crater_arr":           crater_arr,
        "crater_tree":          crater_tree,
        "linear_features":      linear_features,
        "radial_features":      radial_features,
        "populate_polygons":    populate_polygons,
        "populate_points":      populate_points,
        "poly_bboxes":          _poly_bboxes,
        "noise_config":         noise_config,
        "chunks_dir":           chunks_dir,
        "export_dir":           export_dir,
        "nside":                nside,
        "elev_min":             _elev_min,
        "m_per_deg":            m_per_deg,
        "chunk_side_deg":       _chunk_side_deg,
        "MARGIN_DEG":           MARGIN_DEG,
        "max_crater_outer_deg": max_crater_outer_deg,
        "hpx":                  hpx,
    })

    n_workers = max(1, (os.cpu_count() - 1) or 4)
    n_workers = 4
    print(f"  Using {n_workers} worker processes...")
    _t0 = _time.time()
    chunk_manifest = []
    count = 0

    ctx = _mp.get_context("fork")
    with ctx.Pool(n_workers) as pool:
        for entry in pool.imap_unordered(_process_pixel, range(npix), chunksize=32):
            chunk_manifest.append(entry)
            count += 1
            if count % 200 == 0:
                elapsed = _time.time() - _t0
                rate = count / elapsed if elapsed > 0 else 0
                eta = (total - count) / rate if rate > 0 else 0
                print(f"    {count}/{total} recipes... "
                      f"({elapsed:.0f}s elapsed, ~{eta:.0f}s remaining)")
            if count % 1000 == 0:
                memlog_func(f"chunk_recipes: loop {count}/{total}")
            if count == 1:
                memlog_func("chunk_recipes: first iteration done")

    # ── Write manifest JSON ──
    manifest_path = os.path.join(chunks_dir, "chunk_manifest.json")
    manifest_data = {
        "planet_name": planet_name,
        "planet_radius": planet_radius,
        "projection": "healpix",
        "nside": nside,
        "depth": export_depth,
        "total_pixels": npix,
        "format": "recipe",
        "elevation_mode": "contour_segment_idw",
        "elev_min": _elev_min,
        "elev_max": _elev_max,
        "noise_config": noise_config,
        "total_chunks": len(chunk_manifest),
        "total_contour_lines": len(contour_features),
        "total_craters": len(crater_arr),
        "total_linear_features": len(linear_features),
        "total_radial_features": len(radial_features),
        "total_populate_polygons": len(populate_polygons),
        "total_populate_points": len(populate_points),
        "biome_data_in_recipes": True,
        "chunks": chunk_manifest,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest_data, f, indent=2)

    elapsed = _time.time() - _t0
    memlog_func("chunk_recipes: loop finished", f"elapsed={elapsed:.1f}s")
    print(f"  ✓ {count} chunk recipes saved in {chunks_dir} ({elapsed:.1f}s)")
    print(f"  ✓ Manifest: {manifest_path}")
    memlog_func("chunk_recipes: END")
    return chunks_dir


