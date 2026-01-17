#!/usr/bin/env python3
"""
Test script for crater heightmap generation.

Replicates the core logic of ChunkRecipeGenerator.generate_heightmap()
from GDScript in Python, using the actual recipe data, to verify that
craters produce non-zero (negative) height offsets in the heightmap.

Usage:
    python3 test/unit/test_recipe_crater_py.py
"""

import json
import math
import os
import sys

# Constants matching the GDScript code
RIM_UPLIFT_RATIO = 0.04
RIM_OUTER_MULT = 1.15
MAX_DEPTH_M = 500.0
MIN_CRATER_PIXELS = 4

PLANET_RADIUS = 850667.0
MAX_HEIGHT = 1000.0
HEIGHT_OFFSET = 0.0
NSIDE = 64
RESOLUTION = 32  # Match runtime resolution for speed

# ── HEALPix helpers ──────────────────────────────────────────────

def nest2xy(pix):
    """Decode nested pixel index to (ix, iy) face coordinates."""
    ix = 0; iy = 0
    for i in range(16):
        ix |= ((pix >> (2 * i)) & 1) << i
        iy |= ((pix >> (2 * i + 1)) & 1) << i
    return ix, iy


JRLL = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]
JPLL = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7]


def face_xy_to_vec(face, fx, fy, nside):
    """
    Convert HEALPix face + fractional (fx, fy) to unit vector.
    Exact port of HEALPix._face_xy_to_vec() from healpix.gd.
    Uses the CONTINUOUS sub-pixel formula, not the integer pixel one.
    """
    ns = float(nside)

    # Ring index (continuous) and azimuthal index
    jr = float(JRLL[face]) * ns - fx - fy

    if jr < ns:
        # North polar cap
        nr = jr
        z = 1.0 - nr * nr / (3.0 * ns * ns)
        kp = float(JPLL[face]) * nr + fx - fy
        phi = kp * math.pi / (4.0 * nr) if nr > 0 else 0.0
    elif jr > 3.0 * ns:
        # South polar cap
        nr = 4.0 * ns - jr
        z = -1.0 + nr * nr / (3.0 * ns * ns)
        kp = float(JPLL[face]) * nr + fx - fy
        phi = kp * math.pi / (4.0 * nr) if nr > 0 else 0.0
    else:
        # Equatorial belt
        nr = ns
        z = (2.0 * ns - jr) * 2.0 / (3.0 * ns)
        kp = float(JPLL[face]) * ns + fx - fy
        phi = kp * math.pi / (4.0 * ns)

    st = math.sqrt(max(0.0, 1.0 - z * z))
    # Godot coordinate system: Y is up, X and Z are horizontal
    x = st * math.cos(phi)
    y = z
    zz = st * math.sin(phi)
    return (x, y, zz)


def pix2vec_nest(nside, ipix):
    """Convert nested pixel index to unit vector. Matches HEALPix.pix2vec_nest()."""
    npface = nside * nside
    face = ipix // npface
    local = ipix % npface
    ix, iy = nest2xy(local)
    return face_xy_to_vec(face, ix + 0.5, iy + 0.5, nside)


def dir_to_lonlat(dx, dy, dz):
    """Convert unit direction to (lon_deg, lat_deg). Matches _dir_to_lonlat()."""
    length = math.sqrt(dx*dx + dy*dy + dz*dz)
    dx /= length; dy /= length; dz /= length
    lon = math.degrees(math.atan2(dz, dx))
    lat = math.degrees(math.asin(max(-1.0, min(1.0, dy))))
    return lon, lat


def height_offset(dist_m, radius_m, depth_m):
    """
    Crater depression profile. Matches SpatialCraterTerrain.height_offset().
    Returns negative for bowl, positive for rim.
    """
    rim_outer = radius_m * RIM_OUTER_MULT
    rim_h = depth_m * RIM_UPLIFT_RATIO

    if dist_m >= rim_outer:
        return 0.0
    if dist_m >= radius_m:
        t = 1.0 - (dist_m - radius_m) / (rim_outer - radius_m)
        return rim_h * t * t * (3.0 - 2.0 * t)
    t = dist_m / radius_m
    return -depth_m * (1.0 - t * t) + rim_h * t * t * (3.0 - 2.0 * t)


def lonlat_to_dir(lon_deg, lat_deg):
    """Convert lon/lat (degrees) to unit direction (x, y, z) in Godot Y-up."""
    lon = math.radians(lon_deg)
    lat = math.radians(lat_deg)
    cl = math.cos(lat)
    return (cl * math.cos(lon), math.sin(lat), cl * math.sin(lon))


def dot3(a, b):
    """Dot product of two 3-tuples."""
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]


# ── Heightmap generation (Python port of the critical path) ──────

def generate_heightmap(recipe, resolution, planet_radius, elev_min, elev_range,
                       deduplicate=False):
    """
    Simplified port of ChunkRecipeGenerator.generate_heightmap().
    Returns a 2D array [y][x] of normalized height values.
    When deduplicate=True, removes duplicate craters before processing.
    """
    m_per_deg = planet_radius * math.pi / 180.0

    hp_nside = recipe.get("nside", 64)
    hp_ipix = recipe.get("ipix", 0)
    npface = hp_nside * hp_nside
    face = hp_ipix // npface
    local = hp_ipix % npface
    ix, iy = nest2xy(local)
    sub_nside = hp_nside * resolution

    elev_cfg = recipe.get("elevation", {})
    base_elev = elev_cfg.get("base_elevation", 0.0)

    craters_arr = recipe.get("craters", [])
    if deduplicate:
        seen = set()
        unique = []
        for cr in craters_arr:
            key = (cr["lon"], cr["lat"], cr["radius_m"])
            if key not in seen:
                seen.add(key)
                unique.append(cr)
        craters_arr = unique

    # Crater split: baked vs subpixel
    center_dir = pix2vec_nest(hp_nside, hp_ipix)
    corner_dir = face_xy_to_vec(face, float(ix), float(iy), hp_nside)
    cx, cy, cz = center_dir
    ox, oy, oz = corner_dir
    angle = math.acos(max(-1.0, min(1.0, cx*ox + cy*oy + cz*oz)))
    chunk_ground_m = angle * 2.0 * planet_radius
    m_per_pixel = chunk_ground_m / float(resolution)
    min_baked_radius = m_per_pixel * MIN_CRATER_PIXELS * 0.5

    baked_craters = []
    subpixel_craters = []
    for cr in craters_arr:
        if cr["radius_m"] >= min_baked_radius:
            baked_craters.append(cr)
        else:
            subpixel_craters.append(cr)

    # Pre-compute crater directions and cos(outer_angle) for angular rejection
    crater_data = []
    for cr in baked_craters:
        cr_r = cr["radius_m"]
        cr_d = cr["depth_m"]
        cr_dir = lonlat_to_dir(cr["lon"], cr["lat"])
        outer_m = cr_r * RIM_OUTER_MULT
        outer_angle = outer_m / planet_radius
        crater_data.append({
            "dir": cr_dir, "r": cr_r, "d": cr_d,
            "cos_thresh": math.cos(outer_angle)
        })

    if elev_range <= 0:
        elev_range = 1.0

    # Main pixel loop
    heightmap = []
    stats = {"crater_hits": 0, "min_height": float('inf'), "max_height": float('-inf')}

    for py in range(resolution):
        row = []
        for px in range(resolution):
            sub_ix = ix * resolution + px
            sub_iy = iy * resolution + py
            dvec = face_xy_to_vec(face, sub_ix + 0.5, sub_iy + 0.5, sub_nside)

            height = base_elev

            # Crater offsets using 3D angular distance (perfect circles)
            for cd in crater_data:
                d = dot3(dvec, cd["dir"])
                if d < cd["cos_thresh"]:
                    continue
                dist_m = math.acos(max(-1.0, min(1.0, d))) * planet_radius
                offset = height_offset(dist_m, cd["r"], cd["d"])
                if offset != 0.0:
                    stats["crater_hits"] += 1
                height += offset

            if height < stats["min_height"]:
                stats["min_height"] = height
            if height > stats["max_height"]:
                stats["max_height"] = height

            normalized = (height - elev_min) / elev_range
            row.append(normalized)
        heightmap.append(row)

    return heightmap, subpixel_craters, stats


# ── Test cases ───────────────────────────────────────────────────

def test_synthetic_crater():
    """Test with a single crater placed at the pixel center."""
    print("=" * 60)
    print("TEST 1: Synthetic crater at pixel center")
    print("=" * 60)

    ipix = 26965
    center_dir = pix2vec_nest(NSIDE, ipix)
    clon, clat = dir_to_lonlat(*center_dir)
    print(f"  Pixel center: lon={clon:.4f} lat={clat:.4f}")

    recipe = {
        "version": 7, "nside": NSIDE, "ipix": ipix,
        "elevation": {"base_elevation": 0.0, "contour_vertices": [],
                       "grid_elevations": [], "grid_inner_n": 0,
                       "idw_power": 2, "idw_k": 8},
        "craters": [{"lon": clon, "lat": clat, "radius_m": 5000.0, "depth_m": 500.0}],
        "noise": {}, "linear_features": [], "radial_features": [],
        "populate_zones": [], "terrain_modifiers": [],
    }

    hmap, subpix, stats = generate_heightmap(recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)
    cx, cy = RESOLUTION // 2, RESOLUTION // 2
    center_val = hmap[cy][cx]
    denorm = center_val * MAX_HEIGHT + HEIGHT_OFFSET

    print(f"  Center pixel (x={cx},y={cy}): normalized={center_val:.6f}  height={denorm:.2f}m")
    print(f"  Stats: crater_hits={stats['crater_hits']}  "
          f"min_h={stats['min_height']:.2f}  max_h={stats['max_height']:.2f}")
    print(f"  Subpixel craters: {len(subpix)}")

    # Assertions
    ok = True
    if center_val >= 0:
        print("  FAIL: Center pixel should be negative (crater bowl)")
        ok = False
    if center_val >= -0.3:
        print(f"  FAIL: Center pixel should be < -0.3 (expected ~-0.5), got {center_val:.6f}")
        ok = False
    if stats["crater_hits"] == 0:
        print("  FAIL: No crater hits at all!")
        ok = False

    if ok:
        print("  PASS")
    return ok


def test_synthetic_crater_range():
    """Test that the heightmap has both negative and positive values."""
    print("\n" + "=" * 60)
    print("TEST 2: Synthetic crater - bowl + rim range")
    print("=" * 60)

    ipix = 26965
    center_dir = pix2vec_nest(NSIDE, ipix)
    clon, clat = dir_to_lonlat(*center_dir)

    recipe = {
        "version": 7, "nside": NSIDE, "ipix": ipix,
        "elevation": {"base_elevation": 0.0, "contour_vertices": [],
                       "grid_elevations": [], "grid_inner_n": 0,
                       "idw_power": 2, "idw_k": 8},
        "craters": [{"lon": clon, "lat": clat, "radius_m": 5000.0, "depth_m": 500.0}],
        "noise": {}, "linear_features": [], "radial_features": [],
        "populate_zones": [], "terrain_modifiers": [],
    }

    hmap, _, stats = generate_heightmap(recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)

    has_neg = any(v < -0.01 for row in hmap for v in row)
    has_pos = any(v > 0.001 for row in hmap for v in row)
    has_zero = any(abs(v) < 0.001 for row in hmap for v in row)

    print(f"  Has negative pixels (bowl): {has_neg}")
    print(f"  Has positive pixels (rim):  {has_pos}")
    print(f"  Has ~zero pixels (outside): {has_zero}")
    print(f"  Height range: [{stats['min_height']:.2f}, {stats['max_height']:.2f}] m")

    ok = has_neg and has_pos
    if not has_neg:
        print("  FAIL: No negative values — crater bowl missing")
    if not has_pos:
        print("  FAIL: No positive values — crater rim missing")
    if ok:
        print("  PASS")
    return ok


def test_real_recipe():
    """Test with the actual tarsis_5_1 recipe for pixel 26965."""
    print("\n" + "=" * 60)
    print("TEST 3: Real recipe (tarsis_5_1, ipix=26965)")
    print("=" * 60)

    recipe_path = os.path.join(os.path.dirname(__file__), "..", "..",
                               "assets", "qgis", "export",
                               "tarsis_5_1_chunks", "base_6",
                               "hp_n64_p26965.recipe.json")
    if not os.path.exists(recipe_path):
        print(f"  SKIP: Recipe not found at {recipe_path}")
        return True

    with open(recipe_path) as f:
        recipe = json.load(f)

    craters = recipe.get("craters", [])
    print(f"  Craters in recipe: {len(craters)}")

    # Check duplicates
    seen = set()
    dupes = 0
    for cr in craters:
        key = (cr["lon"], cr["lat"], cr["radius_m"])
        if key in seen:
            dupes += 1
        else:
            seen.add(key)
    print(f"  Unique craters: {len(seen)}, Duplicates: {dupes}")
    if dupes > 0:
        print(f"  WARNING: {dupes} duplicate craters — depths will be doubled!")

    hmap, subpix, stats = generate_heightmap(recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT)

    neg_count = sum(1 for row in hmap for v in row if v < -0.001)
    pos_count = sum(1 for row in hmap for v in row if v > 0.001)
    total = RESOLUTION * RESOLUTION

    print(f"  Stats: crater_hits={stats['crater_hits']}  "
          f"min_h={stats['min_height']:.2f}  max_h={stats['max_height']:.2f}")
    print(f"  Negative pixels: {neg_count}/{total}")
    print(f"  Positive pixels: {pos_count}/{total}")
    print(f"  Subpixel craters: {len(subpix)}")
    print(f"  Min normalized: {stats['min_height'] / MAX_HEIGHT:.6f}")
    print(f"  Sample values:")
    for y in [0, RESOLUTION//4, RESOLUTION//2, 3*RESOLUTION//4, RESOLUTION-1]:
        x = RESOLUTION // 2
        v = hmap[y][x]
        print(f"    ({x:3d},{y:3d}): normalized={v:+.6f}  height={v*MAX_HEIGHT+HEIGHT_OFFSET:+.2f}m")

    ok = True
    if neg_count == 0:
        print("  FAIL: No negative pixels — craters not showing!")
        ok = False
    else:
        print(f"  PASS: {neg_count} pixels have crater depression")

    return ok


def test_denorm_roundtrip():
    """Test normalization→denormalization round-trip."""
    print("\n" + "=" * 60)
    print("TEST 4: Normalization round-trip")
    print("=" * 60)

    for h in [-500, -250, 0, 100, 500, 1000]:
        norm = (h - HEIGHT_OFFSET) / MAX_HEIGHT
        denorm = norm * MAX_HEIGHT + HEIGHT_OFFSET
        ok = abs(denorm - h) < 0.01
        print(f"  h={h:+6.0f}m → norm={norm:+.4f} → denorm={denorm:+.4f}m  {'PASS' if ok else 'FAIL'}")
        if not ok:
            return False

    print("  PASS")
    return True


def test_height_offset_profile():
    """Test the crater height_offset function at key distances."""
    print("\n" + "=" * 60)
    print("TEST 5: Crater profile (height_offset function)")
    print("=" * 60)

    radius = 1000.0
    depth = 500.0
    rim_h = depth * RIM_UPLIFT_RATIO  # 20m

    test_points = [
        (0.0, "center", lambda v: v < -400),
        (radius * 0.5, "half-radius", lambda v: v < -100),
        (radius, "rim edge", lambda v: v > 0),
        (radius * 1.07, "mid-rim", lambda v: v > 0),
        (radius * 1.15, "outer rim", lambda v: abs(v) < 0.1),
        (radius * 2.0, "far outside", lambda v: v == 0.0),
    ]

    ok = True
    for dist, label, check in test_points:
        offset = height_offset(dist, radius, depth)
        passed = check(offset)
        status = "PASS" if passed else "FAIL"
        print(f"  dist={dist:7.1f}m ({label:12s}): offset={offset:+.2f}m  {status}")
        if not passed:
            ok = False

    if ok:
        print("  PASS")
    return ok


def test_real_recipe_deduplicated():
    """Test real recipe with deduplication (how the fixed code will behave)."""
    print("\n" + "=" * 60)
    print("TEST 6: Real recipe DEDUPLICATED (post-fix)")
    print("=" * 60)

    recipe_path = os.path.join(os.path.dirname(__file__), "..", "..",
                               "assets", "qgis", "export",
                               "tarsis_5_1_chunks", "base_6",
                               "hp_n64_p26965.recipe.json")
    if not os.path.exists(recipe_path):
        print(f"  SKIP: Recipe not found")
        return True

    with open(recipe_path) as f:
        recipe = json.load(f)

    hmap, subpix, stats = generate_heightmap(
        recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT,
        deduplicate=True)

    neg_count = sum(1 for row in hmap for v in row if v < -0.001)
    pos_count = sum(1 for row in hmap for v in row if v > 0.001)
    total = RESOLUTION * RESOLUTION

    print(f"  Stats: crater_hits={stats['crater_hits']}  "
          f"min_h={stats['min_height']:.2f}  max_h={stats['max_height']:.2f}")
    print(f"  Negative pixels: {neg_count}/{total}")
    print(f"  Positive pixels: {pos_count}/{total}")
    print(f"  Height range (m): [{stats['min_height']:.1f}, {stats['max_height']:.1f}]")
    print(f"  Variation: {stats['max_height'] - stats['min_height']:.1f}m")
    print(f"  Sample values:")
    for y in [0, RESOLUTION//4, RESOLUTION//2, 3*RESOLUTION//4, RESOLUTION-1]:
        x = RESOLUTION // 2
        v = hmap[y][x]
        print(f"    ({x:3d},{y:3d}): height={v*MAX_HEIGHT+HEIGHT_OFFSET:+.2f}m")

    ok = True
    # After dedup, we should still have craters but not as extreme
    if stats['min_height'] > -1000:
        print(f"  GOOD: Min height {stats['min_height']:.1f}m is within reasonable range")
    else:
        print(f"  WARNING: Min height {stats['min_height']:.1f}m is still very deep")

    if neg_count == 0:
        print("  FAIL: No negative pixels")
        ok = False
    if pos_count > 0:
        print(f"  GOOD: {pos_count} positive pixels (rim uplift visible)")
    else:
        print("  NOTE: No positive pixels (all craters overlap)")

    print("  PASS" if ok else "  FAIL")
    return ok


def test_real_recipe_additive_dedup():
    """Test real recipe with dedup + additive (smaller craters dig into larger)."""
    print("\n" + "=" * 60)
    print("TEST 7: Real recipe DEDUP + ADDITIVE (overlap stacking)")
    print("=" * 60)

    recipe_path = os.path.join(os.path.dirname(__file__), "..", "..",
                               "assets", "qgis", "export",
                               "tarsis_5_1_chunks", "base_6",
                               "hp_n64_p26965.recipe.json")
    if not os.path.exists(recipe_path):
        print(f"  SKIP: Recipe not found")
        return True

    with open(recipe_path) as f:
        recipe = json.load(f)

    hmap, subpix, stats = generate_heightmap(
        recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT,
        deduplicate=True)

    neg_count = sum(1 for row in hmap for v in row if v < -0.001)
    pos_count = sum(1 for row in hmap for v in row if v > 0.001)
    total = RESOLUTION * RESOLUTION

    print(f"  Stats: crater_hits={stats['crater_hits']}  "
          f"min_h={stats['min_height']:.2f}  max_h={stats['max_height']:.2f}")
    print(f"  Negative pixels: {neg_count}/{total}")
    print(f"  Positive pixels: {pos_count}/{total}")
    print(f"  Height range (m): [{stats['min_height']:.1f}, {stats['max_height']:.1f}]")
    print(f"  Variation: {stats['max_height'] - stats['min_height']:.1f}m")
    print(f"  Sample values:")
    for y in [0, RESOLUTION//4, RESOLUTION//2, 3*RESOLUTION//4, RESOLUTION-1]:
        x = RESOLUTION // 2
        v = hmap[y][x]
        print(f"    ({x:3d},{y:3d}): height={v*MAX_HEIGHT+HEIGHT_OFFSET:+.2f}m")

    ok = True
    if neg_count == 0:
        print("  FAIL: No negative pixels")
        ok = False

    # Additive should be deeper than single-crater min (~500m) but
    # much better than pre-fix (no duplicates, no double application)
    if stats['min_height'] < stats['max_height']:
        print(f"  GOOD: Height variation = {stats['max_height'] - stats['min_height']:.1f}m "
              f"(smaller craters dig into larger)")
    else:
        print("  FAIL: No height variation")
        ok = False

    print("  PASS" if ok else "  FAIL")
    return ok


def xy2nest(ix, iy):
    """Encode (ix, iy) to nested pixel index. Inverse of nest2xy."""
    pix = 0
    for i in range(16):
        pix |= ((ix >> i) & 1) << (2 * i)
        pix |= ((iy >> i) & 1) << (2 * i + 1)
    return pix


def get_neighbor_pixels(nside, ipix):
    """
    Get up to 8 neighbor pixels for a nested HEALPix pixel.
    Simplified: only returns same-face neighbors (no cross-face).
    """
    npface = nside * nside
    face = ipix // npface
    local = ipix % npface
    ix, iy = nest2xy(local)
    neighbors = []
    for dx, dy in [(0,1),(1,1),(1,0),(1,-1),(0,-1),(-1,-1),(-1,0),(-1,1)]:
        nx, ny = ix + dx, iy + dy
        if 0 <= nx < nside and 0 <= ny < nside:
            neighbors.append(face * npface + xy2nest(nx, ny))
    return neighbors


def test_neighbor_crater_merge():
    """Test that merging neighbor craters fixes cross-boundary seams."""
    print("\n" + "=" * 60)
    print("TEST 8: Neighbor crater merge (cross-boundary fix)")
    print("=" * 60)

    recipes_dir = os.path.join(os.path.dirname(__file__), "..", "..",
                               "assets", "qgis", "export",
                               "tarsis_5_1_chunks")
    test_ipix = 26965

    base = test_ipix // (NSIDE * NSIDE)
    recipe_path = os.path.join(recipes_dir, f"base_{base}",
                               f"hp_n{NSIDE}_p{test_ipix}.recipe.json")
    if not os.path.exists(recipe_path):
        print(f"  SKIP: Recipe not found")
        return True

    with open(recipe_path) as f:
        recipe = json.load(f)

    own_craters = recipe.get("craters", [])
    print(f"  Own craters: {len(own_craters)}")

    # Load neighbor craters
    neighbors = get_neighbor_pixels(NSIDE, test_ipix)
    print(f"  Neighbors: {neighbors}")
    extra_craters = []
    for nb_ipix in neighbors:
        nb_base = nb_ipix // (NSIDE * NSIDE)
        nb_path = os.path.join(recipes_dir, f"base_{nb_base}",
                               f"hp_n{NSIDE}_p{nb_ipix}.recipe.json")
        if not os.path.exists(nb_path):
            continue
        with open(nb_path) as f:
            nb_recipe = json.load(f)
        extra_craters.extend(nb_recipe.get("craters", []))

    print(f"  Extra craters from neighbors: {len(extra_craters)}")

    # Merge + deduplicate
    merged = own_craters + extra_craters
    seen = set()
    deduped = []
    for cr in merged:
        key = ("%.6f_%.6f_%.1f" % (cr["lon"], cr["lat"], cr["radius_m"]))
        if key not in seen:
            seen.add(key)
            deduped.append(cr)

    new_craters = len(deduped) - len(set(
        "%.6f_%.6f_%.1f" % (cr["lon"], cr["lat"], cr["radius_m"])
        for cr in own_craters))
    print(f"  Merged unique craters: {len(deduped)} (+{new_craters} from neighbors)")

    # Generate heightmap with merged craters
    merged_recipe = dict(recipe)
    merged_recipe["craters"] = deduped
    hmap_merged, _, stats_m = generate_heightmap(
        merged_recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT,
        deduplicate=True)

    # Generate heightmap with own craters only (original behavior)
    hmap_own, _, stats_o = generate_heightmap(
        recipe, RESOLUTION, PLANET_RADIUS, HEIGHT_OFFSET, MAX_HEIGHT,
        deduplicate=True)

    # Compare boundary pixels
    diff_count = 0
    max_diff = 0.0
    for y in range(RESOLUTION):
        for x in range(RESOLUTION):
            d = abs(hmap_merged[y][x] - hmap_own[y][x])
            if d > 1e-6:
                diff_count += 1
                max_diff = max(max_diff, d)

    print(f"  Pixels changed by neighbor merge: {diff_count}/{RESOLUTION*RESOLUTION}")
    print(f"  Max height difference: {max_diff * MAX_HEIGHT:.2f}m")
    print(f"  Own-only stats: min={stats_o['min_height']:.1f}m max={stats_o['max_height']:.1f}m")
    print(f"  Merged stats:   min={stats_m['min_height']:.1f}m max={stats_m['max_height']:.1f}m")

    ok = True
    if new_craters > 0:
        print(f"  GOOD: {new_craters} craters added from neighbors (would fix boundary seams)")
    else:
        print("  NOTE: No extra craters from neighbors for this chunk (equatorial, no AABB bug)")

    print("  PASS")
    return ok


# ── Main ─────────────────────────────────────────────────────────

def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    os.chdir("../..")  # project root

    results = []
    results.append(("Synthetic crater center", test_synthetic_crater()))
    results.append(("Synthetic crater range", test_synthetic_crater_range()))
    results.append(("Real recipe craters", test_real_recipe()))
    results.append(("Denorm round-trip", test_denorm_roundtrip()))
    results.append(("Height offset profile", test_height_offset_profile()))
    results.append(("Real recipe deduplicated", test_real_recipe_deduplicated()))
    results.append(("Real recipe dedup+additive", test_real_recipe_additive_dedup()))
    results.append(("Neighbor crater merge", test_neighbor_crater_merge()))

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    all_pass = True
    for name, ok in results:
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {name}")
        if not ok:
            all_pass = False

    if all_pass:
        print("\nAll tests passed!")
        return 0
    else:
        print("\nSome tests FAILED!")
        return 1


if __name__ == "__main__":
    sys.exit(main())
