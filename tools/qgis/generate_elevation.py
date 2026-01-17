"""
QGIS Elevation Generator for StarDeception
============================================
Generates realistic terrain elevation contour lines across the entire planet
using fractal noise (FBM + ridged), then writes them into the existing
contours layer.  Ocean areas (maritime_river-ocean polygons) are clamped
to a flat sea-level elevation.

Usage:
    1. Open your planet project in QGIS (created by setup_planet_project.py)
    2. Make sure the contours layer and maritime_river-ocean layer exist
    3. Open Python Console (Ctrl+Alt+P)
    4. Paste this script or run:
         exec(open('/datas/developpement/sources/StarDeception/StarDeception/tools/qgis/generate_elevation.py').read())

The script populates the contours layer with LineString features.
After running, use export_planet.py to generate chunked heightmaps.
"""

import math
import os
import time

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsFeature,
    QgsGeometry,
    QgsPointXY,
    QgsField,
    QgsExpressionContextUtils,
)
from qgis.PyQt.QtCore import QVariant


# ============================================================
# CONFIGURATION — edit these before running
# ============================================================

# ── Planet identity ────────────────────────────────────────────
# Read automatically from the QGIS project variables set by
# setup_planet_project.py.  No need to edit these manually.

# ── Elevation range (metres) ──────────────────────────────────
# ELEVATION_MIN: deepest terrain point (ocean floor, negative values ok).
# ELEVATION_MAX: highest mountain peak.
# Together they define the full vertical range of the planet.
ELEVATION_MIN = -200.0
ELEVATION_MAX = 1000.0

# ── Sea level (metres) ────────────────────────────────────────
# Terrain inside ocean polygons is clamped flat to this elevation.
# Typically 0.0 — sea level by convention.
SEA_LEVEL = 0.0

# ── Noise shape ───────────────────────────────────────────────
# NOISE_OCTAVES: number of fractal layers.  More octaves = more fine
#   detail on top of the large shapes.  6–8 is realistic.
NOISE_OCTAVES = 6

# NOISE_FREQUENCY: base frequency of the largest noise features.
#   Lower values → broader, continent-scale shapes.
#   Higher values → more crowded terrain.
#   Typical: 1.5–4.0
NOISE_FREQUENCY = 2.0

# NOISE_LACUNARITY: frequency multiplier between octaves.
#   2.0 is standard; <2 = smoother blending, >2 = sharper jumps.
NOISE_LACUNARITY = 1.5

# NOISE_PERSISTENCE: amplitude decay per octave (0–1).
#   Higher = the small details are almost as tall as the big shapes.
#   Lower = the big continental shapes dominate.  0.45–0.55 is typical.
NOISE_PERSISTENCE = 0.50

# NOISE_SEED: integer seed for reproducibility.
#   Change this to get a completely different terrain layout.
NOISE_SEED = 21

# ── Terrain realism ───────────────────────────────────────────
# MOUNTAIN_EXPONENT: power curve applied to positive elevations.
#   1.0 = linear (uniform slope distribution).
#   2.0 = most terrain is flat lowland with occasional sharp peaks.
#   3.0 = extremely flat with rare very tall mountains.
MOUNTAIN_EXPONENT = 2.0

# RIDGE_NOISE_WEIGHT: blend between smooth FBM and ridged noise (0–1).
#   0.0 = pure smooth FBM (rolling hills, no sharp ridges).
#   1.0 = pure ridged (mountain chains with deep valleys).
#   0.3 = gentle ridges mixed into otherwise smooth terrain.
RIDGE_NOISE_WEIGHT = 1.0

# COASTAL_FALLOFF_DEG: distance in degrees from ocean polygon edges
#   where terrain smoothly ramps down toward SEA_LEVEL.
#   Prevents harsh cliffs at coastlines.
#   1 degree ≈ planet_circumference / 360.
#   Typical: 0.5–3.0 degrees.
COASTAL_FALLOFF_DEG = 2.0

# ── Contour output ────────────────────────────────────────────
# CONTOUR_INTERVAL: vertical spacing between contour lines (metres).
#   Smaller = more vector features in QGIS (slower).
#   50m is a good balance.  Minimum practical: ~10m.
CONTOUR_INTERVAL = 50.0

# ── Raster resolution (internal) ──────────────────────────────
# Resolution of the intermediate elevation grid used to extract contours.
# Higher = more detailed contour lines but slower generation.
# The grid covers -180..180 longitude, -90..90 latitude.
RASTER_WIDTH = 2048
RASTER_HEIGHT = 1024


# ============================================================
# NOISE FUNCTIONS (pure Python — no external deps)
# ============================================================

def _hash2d(ix, iy, seed):
    """Integer lattice hash → float in [0, 1)."""
    # Simple hash combining coordinates and seed
    n = ix * 374761393 + iy * 668265263 + seed * 1274126177
    n = (n ^ (n >> 13)) * 1274126177
    n = n ^ (n >> 16)
    return (n & 0x7FFFFFFF) / 2147483648.0


def _grad2d(ix, iy, fx, fy, seed):
    """2D gradient noise contribution from lattice point (ix,iy)."""
    h = int(_hash2d(ix, iy, seed) * 4.0) & 3
    if h == 0:
        return fx + fy
    elif h == 1:
        return -fx + fy
    elif h == 2:
        return fx - fy
    else:
        return -fx - fy


def _smoothstep(t):
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def perlin2d(x, y, seed=0):
    """Single-octave 2D Perlin noise, returns roughly [-1, 1]."""
    ix = int(math.floor(x))
    iy = int(math.floor(y))
    fx = x - ix
    fy = y - iy
    u = _smoothstep(fx)
    v = _smoothstep(fy)
    n00 = _grad2d(ix, iy, fx, fy, seed)
    n10 = _grad2d(ix + 1, iy, fx - 1.0, fy, seed)
    n01 = _grad2d(ix, iy + 1, fx, fy - 1.0, seed)
    n11 = _grad2d(ix + 1, iy + 1, fx - 1.0, fy - 1.0, seed)
    nx0 = n00 + u * (n10 - n00)
    nx1 = n01 + u * (n11 - n01)
    return nx0 + v * (nx1 - nx0)


def fbm2d(x, y, octaves, frequency, lacunarity, persistence, seed):
    """Fractal Brownian Motion — stacks multiple Perlin octaves."""
    value = 0.0
    amp = 1.0
    freq = frequency
    max_amp = 0.0
    for i in range(octaves):
        value += perlin2d(x * freq, y * freq, seed + i * 31) * amp
        max_amp += amp
        freq *= lacunarity
        amp *= persistence
    return value / max_amp  # Normalize to roughly [-1, 1]


def ridged2d(x, y, octaves, frequency, lacunarity, persistence, seed):
    """Ridged multifractal noise — sharp ridges and valleys."""
    value = 0.0
    amp = 1.0
    freq = frequency
    max_amp = 0.0
    prev = 1.0
    for i in range(octaves):
        n = perlin2d(x * freq, y * freq, seed + i * 31 + 1000)
        n = 1.0 - abs(n)  # Fold to create ridges
        n = n * n          # Sharpen the ridges
        n *= prev          # Successive octaves modulated by previous
        prev = n
        value += n * amp
        max_amp += amp
        freq *= lacunarity
        amp *= persistence
    return value / max_amp  # Normalize to roughly [0, 1]


# ============================================================
# OCEAN MASK HELPERS
# ============================================================

def _build_ocean_raster(ocean_layer, width, height):
    """
    Rasterise ocean polygons into a boolean grid.
    True = ocean (should be clamped to SEA_LEVEL).

    Also builds a distance-from-coast grid (in degrees) for the
    coastal falloff blending.
    """
    print("  Building ocean mask raster...")
    ocean_mask = [[False] * width for _ in range(height)]

    if ocean_layer is None or ocean_layer.featureCount() == 0:
        print("  ⚠ No ocean features found — skipping ocean mask")
        return ocean_mask, None

    # Collect ocean polygon geometries
    ocean_geoms = []
    for feat in ocean_layer.getFeatures():
        geom = feat.geometry()
        if geom and not geom.isNull():
            ocean_geoms.append(geom)

    if not ocean_geoms:
        return ocean_mask, None

    # Merge all ocean polygons into one for faster point-in-polygon
    merged = ocean_geoms[0]
    for g in ocean_geoms[1:]:
        merged = merged.combine(g)

    lon_step = 360.0 / width
    lat_step = 180.0 / height

    for row in range(height):
        lat = 90.0 - (row + 0.5) * lat_step
        for col in range(width):
            lon = -180.0 + (col + 0.5) * lon_step
            pt = QgsPointXY(lon, lat)
            if merged.contains(QgsGeometry.fromPointXY(pt)):
                ocean_mask[row][col] = True

    ocean_count = sum(sum(1 for v in r if v) for r in ocean_mask)
    total = width * height
    print(f"  ✓ Ocean mask: {ocean_count}/{total} cells "
          f"({100.0 * ocean_count / total:.1f}%)")

    # Build distance-from-coast grid (simplified: BFS in pixel steps)
    dist_grid = None
    if COASTAL_FALLOFF_DEG > 0:
        print("  Building coastal distance grid...")
        dist_grid = _build_coast_distance(ocean_mask, width, height,
                                          lon_step, lat_step)
        print("  ✓ Coastal distance grid built")

    return ocean_mask, dist_grid


def _build_coast_distance(ocean_mask, width, height, lon_step, lat_step):
    """
    BFS flood-fill from ocean edges to compute approximate distance
    in degrees from the nearest coastline for each land cell.

    Returns a 2D array of floats (degrees).  Ocean cells get 0.0.
    """
    from collections import deque

    INF = 1e9
    dist = [[INF] * width for _ in range(height)]

    queue = deque()

    # Seed: land cells adjacent to ocean cells
    for row in range(height):
        for col in range(width):
            if ocean_mask[row][col]:
                dist[row][col] = 0.0
                continue
            # Check 4-neighbours for ocean
            for dr, dc in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                nr = row + dr
                nc = (col + dc) % width  # Wrap longitude
                if nr < 0 or nr >= height:
                    continue
                if ocean_mask[nr][nc]:
                    # This land cell borders ocean
                    d = math.sqrt((dr * lat_step) ** 2 + (dc * lon_step) ** 2)
                    if d < dist[row][col]:
                        dist[row][col] = d
                        queue.append((row, col))
                    break

    # BFS expand up to COASTAL_FALLOFF_DEG
    max_dist = COASTAL_FALLOFF_DEG
    while queue:
        row, col = queue.popleft()
        if dist[row][col] > max_dist:
            continue
        for dr, dc in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            nr = row + dr
            nc = (col + dc) % width
            if nr < 0 or nr >= height:
                continue
            if ocean_mask[nr][nc]:
                continue
            step_d = math.sqrt((dr * lat_step) ** 2 + (dc * lon_step) ** 2)
            new_dist = dist[row][col] + step_d
            if new_dist < dist[nr][nc]:
                dist[nr][nc] = new_dist
                if new_dist <= max_dist:
                    queue.append((nr, nc))

    return dist


# ============================================================
# CONTOUR EXTRACTION (marching squares)
# ============================================================

def _extract_contours(elev_grid, width, height, level):
    """
    Simple marching-squares contour extraction at the given elevation level.
    Returns a list of polylines, each a list of (lon, lat) tuples.
    """
    lon_step = 360.0 / width
    lat_step = 180.0 / height

    segments = []

    for row in range(height - 1):
        for col in range(width - 1):
            # Four corners of this cell
            v00 = elev_grid[row][col]
            v10 = elev_grid[row][col + 1]
            v01 = elev_grid[row + 1][col]
            v11 = elev_grid[row + 1][col + 1]

            # Classify corners above/below the contour level
            case = 0
            if v00 >= level:
                case |= 1
            if v10 >= level:
                case |= 2
            if v01 >= level:
                case |= 4
            if v11 >= level:
                case |= 8

            if case == 0 or case == 15:
                continue

            # Cell corners in geographic coords
            lon0 = -180.0 + col * lon_step
            lon1 = lon0 + lon_step
            lat0 = 90.0 - row * lat_step
            lat1 = lat0 - lat_step

            # Interpolate edge crossings
            def interp_lon(va, vb, la, lb):
                if abs(vb - va) < 1e-10:
                    return (la + lb) * 0.5
                t = (level - va) / (vb - va)
                return la + t * (lb - la)

            # Edge midpoints where contour crosses
            # Top edge: v00 — v10
            top = (interp_lon(v00, v10, lon0, lon1), lat0) if (case & 1) != (case & 2) else None
            # Bottom edge: v01 — v11
            bot = (interp_lon(v01, v11, lon0, lon1), lat1) if (case & 4) != (case & 8) else None
            # Left edge: v00 — v01
            left = (lon0, interp_lon(v00, v01, lat0, lat1)) if (case & 1) != (case & 4) else None
            # Right edge: v10 — v11
            right = (lon1, interp_lon(v10, v11, lat0, lat1)) if (case & 2) != (case & 8) else None

            edges = [e for e in [top, bot, left, right] if e is not None]

            # Standard marching squares: connect pairs of edge crossings
            if case in (1, 14):
                if top and left:
                    segments.append((top, left))
            elif case in (2, 13):
                if top and right:
                    segments.append((top, right))
            elif case in (4, 11):
                if bot and left:
                    segments.append((bot, left))
            elif case in (8, 7):
                if bot and right:
                    segments.append((bot, right))
            elif case in (3, 12):
                if left and right:
                    segments.append((left, right))
            elif case in (5, 10):
                if top and bot:
                    segments.append((top, bot))
            elif case == 6:
                # Saddle — disambiguate with center value
                center = (v00 + v10 + v01 + v11) * 0.25
                if center >= level:
                    if top and left:
                        segments.append((top, left))
                    if bot and right:
                        segments.append((bot, right))
                else:
                    if top and right:
                        segments.append((top, right))
                    if bot and left:
                        segments.append((bot, left))
            elif case == 9:
                center = (v00 + v10 + v01 + v11) * 0.25
                if center >= level:
                    if top and right:
                        segments.append((top, right))
                    if bot and left:
                        segments.append((bot, left))
                else:
                    if top and left:
                        segments.append((top, left))
                    if bot and right:
                        segments.append((bot, right))

    if not segments:
        return []

    # Chain segments into polylines
    return _chain_segments(segments)


def _chain_segments(segments):
    """Chain individual segments into longer polylines."""
    from collections import defaultdict

    EPSILON = 1e-8

    def snap(pt):
        return (round(pt[0], 6), round(pt[1], 6))

    adj = defaultdict(list)
    for i, (a, b) in enumerate(segments):
        sa, sb = snap(a), snap(b)
        adj[sa].append((sb, i))
        adj[sb].append((sa, i))

    used = [False] * len(segments)
    polylines = []

    for i, (a, b) in enumerate(segments):
        if used[i]:
            continue
        used[i] = True
        chain = [snap(a), snap(b)]

        # Extend forward from chain[-1]
        while True:
            tail = chain[-1]
            extended = False
            for (other, idx) in adj[tail]:
                if not used[idx]:
                    used[idx] = True
                    chain.append(other)
                    extended = True
                    break
            if not extended:
                break

        # Extend backward from chain[0]
        while True:
            head = chain[0]
            extended = False
            for (other, idx) in adj[head]:
                if not used[idx]:
                    used[idx] = True
                    chain.insert(0, other)
                    extended = True
                    break
            if not extended:
                break

        if len(chain) >= 2:
            polylines.append(chain)

    return polylines


# ============================================================
# MAIN GENERATION
# ============================================================

def generate_elevation():
    """Main entry point — generates elevation and writes contours."""
    t0 = time.time()

    project = QgsProject.instance()
    scope = QgsExpressionContextUtils.projectScope(project)
    PLANET_NAME = scope.variable("planet_name")
    if not PLANET_NAME:
        print("  ✗ Project variable 'planet_name' not set."
              " Run setup_planet_project.py first.")
        return

    print("=" * 60)
    print("  Elevation Generator for StarDeception")
    print("=" * 60)
    print()
    print(f"  Planet:           {PLANET_NAME}")
    print(f"  Elevation range:  {ELEVATION_MIN} .. {ELEVATION_MAX} m")
    print(f"  Sea level:        {SEA_LEVEL} m")
    print(f"  Noise:            {NOISE_OCTAVES} octaves, freq={NOISE_FREQUENCY}, "
          f"seed={NOISE_SEED}")
    print(f"  Ridge weight:     {RIDGE_NOISE_WEIGHT}")
    print(f"  Mountain exp:     {MOUNTAIN_EXPONENT}")
    print(f"  Coastal falloff:  {COASTAL_FALLOFF_DEG}°")
    print(f"  Contour interval: {CONTOUR_INTERVAL} m")
    print(f"  Grid resolution:  {RASTER_WIDTH}×{RASTER_HEIGHT}")
    print()

    # ── 1. Find the contours layer ──────────────────────────────
    # Match by display name: setup_planet_project.py sets it to 'contours'
    # (via biome_display_name, which strips the planet prefix).
    print("[1/5] Locating contours layer...")
    contours_layer = None
    for layer in project.mapLayers().values():
        if isinstance(layer, QgsVectorLayer) and layer.name() == "contours":
            contours_layer = layer
            break
    if contours_layer is None:
        print("  ✗ Could not find contours layer.  "
              "Run setup_planet_project.py first.")
        return
    print(f"  ✓ Found: {contours_layer.name()} "
          f"({contours_layer.featureCount()} existing features)")

    # ── 2. Find the ocean layer (optional) ──────────────────────
    # Match by the layer custom property set in setup_planet_project.py,
    # or fall back to display name.  The PostGIS table name uses underscores
    # ('maritime_river_ocean') so we cannot match on the hyphenated biome type
    # via the source URI — use the layer metadata instead.
    print("\n[2/5] Locating ocean layer...")
    ocean_layer = None
    for layer in project.mapLayers().values():
        if isinstance(layer, QgsVectorLayer):
            if layer.customProperty("biome_type") == "maritime_river-ocean":
                ocean_layer = layer
                break
    if ocean_layer is None:
        # Fallback: match display name '[maritime river] ocean'
        for layer in project.mapLayers().values():
            if isinstance(layer, QgsVectorLayer) and layer.name() == "[maritime river] ocean":
                ocean_layer = layer
                break
    if ocean_layer and ocean_layer.featureCount() > 0:
        print(f"  ✓ Found: {ocean_layer.name()} "
              f"({ocean_layer.featureCount()} features)")
    else:
        print("  ⚠ No ocean layer or no features — "
              "terrain will cover the entire planet")
        ocean_layer = None

    # ── 3. Build elevation grid ─────────────────────────────────
    print("\n[3/5] Generating elevation grid...")
    w, h = RASTER_WIDTH, RASTER_HEIGHT
    lon_step = 360.0 / w
    lat_step = 180.0 / h

    # Build ocean mask + coast distance
    ocean_mask, coast_dist = _build_ocean_raster(ocean_layer, w, h)

    elev_range = ELEVATION_MAX - ELEVATION_MIN
    positive_range = ELEVATION_MAX - SEA_LEVEL

    print(f"  Generating {w}×{h} elevation samples...")
    elev_grid = [[0.0] * w for _ in range(h)]

    for row in range(h):
        if row % 100 == 0:
            pct = 100.0 * row / h
            print(f"    {pct:.0f}%...")
        lat = 90.0 - (row + 0.5) * lat_step
        # Convert lat to [-1, 1] range for noise
        lat_n = lat / 90.0
        for col in range(w):
            lon = -180.0 + (col + 0.5) * lon_step
            # Convert lon to [-1, 1] range for noise
            lon_n = lon / 180.0

            # ── Spherical coordinates for seamless noise ──
            # Map lon/lat to 3D sphere surface, then project
            # to 2D noise coords to avoid seams at ±180°.
            theta = math.radians(lon)
            phi = math.radians(90.0 - lat)
            nx = math.sin(phi) * math.cos(theta)
            ny = math.sin(phi) * math.sin(theta)
            nz = math.cos(phi)
            # Use two orthogonal 2D slices of the 3D position
            # for seamless spherical noise.
            u1 = nx + nz * 0.37
            v1 = ny + nz * 0.73

            # ── FBM noise (smooth rolling terrain) ──
            n_fbm = fbm2d(u1, v1, NOISE_OCTAVES, NOISE_FREQUENCY,
                          NOISE_LACUNARITY, NOISE_PERSISTENCE, NOISE_SEED)

            # ── Ridged noise (mountain chains) ──
            n_ridge = ridged2d(u1, v1, NOISE_OCTAVES, NOISE_FREQUENCY,
                               NOISE_LACUNARITY, NOISE_PERSISTENCE,
                               NOISE_SEED + 77)

            # ── Blend FBM and ridged ──
            # n_ridge is [0,1], shift to [-1,1] range like FBM
            n_ridge_centered = n_ridge * 2.0 - 1.0
            raw = (1.0 - RIDGE_NOISE_WEIGHT) * n_fbm + \
                  RIDGE_NOISE_WEIGHT * n_ridge_centered

            # raw is roughly [-1, 1].  Map to elevation:
            # Positive values → apply mountain exponent for sharper peaks.
            # Negative values → linear mapping into below-sea-level.
            if raw >= 0:
                t = raw  # [0, 1]
                t = t ** MOUNTAIN_EXPONENT  # Sharpen peaks
                elevation = SEA_LEVEL + t * positive_range
            else:
                t = -raw  # [0, 1]
                elevation = SEA_LEVEL - t * (SEA_LEVEL - ELEVATION_MIN)

            # ── Ocean clamping ──
            if ocean_mask[row][col]:
                elevation = SEA_LEVEL
            elif coast_dist is not None and COASTAL_FALLOFF_DEG > 0:
                d = coast_dist[row][col]
                if d < COASTAL_FALLOFF_DEG:
                    # Smooth blend toward sea level near coasts
                    blend = d / COASTAL_FALLOFF_DEG
                    # Smoothstep for natural transition
                    blend = blend * blend * (3.0 - 2.0 * blend)
                    elevation = SEA_LEVEL + (elevation - SEA_LEVEL) * blend

            # Clamp to configured range
            elevation = max(ELEVATION_MIN, min(ELEVATION_MAX, elevation))
            elev_grid[row][col] = elevation

    print("    100%")

    # Stats
    flat_vals = [elev_grid[r][c] for r in range(h) for c in range(w)]
    e_min = min(flat_vals)
    e_max = max(flat_vals)
    e_avg = sum(flat_vals) / len(flat_vals)
    print(f"  ✓ Elevation grid complete: "
          f"min={e_min:.1f}m  max={e_max:.1f}m  avg={e_avg:.1f}m")

    # ── 4. Extract contour lines ────────────────────────────────
    print(f"\n[4/5] Extracting contours (interval={CONTOUR_INTERVAL}m)...")

    # Determine contour levels
    level_min = math.ceil(ELEVATION_MIN / CONTOUR_INTERVAL) * CONTOUR_INTERVAL
    level_max = math.floor(ELEVATION_MAX / CONTOUR_INTERVAL) * CONTOUR_INTERVAL
    levels = []
    level = level_min
    while level <= level_max:
        levels.append(level)
        level += CONTOUR_INTERVAL
    print(f"  {len(levels)} contour levels from {levels[0]}m to {levels[-1]}m")

    all_features = []
    for i, level_val in enumerate(levels):
        if i % 20 == 0:
            print(f"    Level {level_val:.0f}m ({i + 1}/{len(levels)})...")
        polylines = _extract_contours(elev_grid, w, h, level_val)
        for polyline in polylines:
            if len(polyline) < 2:
                continue
            # Skip tiny contours (< 3 unique points)
            if len(polyline) < 3:
                continue
            feat = QgsFeature(contours_layer.fields())
            feat.setAttribute("elevation", float(level_val))
            feat.setAttribute("type", "contour")
            feat.setAttribute("interval", float(CONTOUR_INTERVAL))
            points = [QgsPointXY(pt[0], pt[1]) for pt in polyline]
            feat.setGeometry(QgsGeometry.fromPolylineXY(points))
            all_features.append(feat)

    print(f"  ✓ Extracted {len(all_features)} contour features")

    # ── 5. Write features to the contours layer ─────────────────
    print(f"\n[5/5] Writing {len(all_features)} features to contours layer...")

    contours_layer.startEditing()

    # Clear existing contour features (generated ones only)
    existing_ids = [f.id() for f in contours_layer.getFeatures()]
    if existing_ids:
        print(f"  Clearing {len(existing_ids)} existing features...")
        contours_layer.deleteFeatures(existing_ids)

    # Add new features in batches
    batch_size = 1000
    added = 0
    for i in range(0, len(all_features), batch_size):
        batch = all_features[i:i + batch_size]
        contours_layer.addFeatures(batch)
        added += len(batch)
        if added % 5000 == 0:
            print(f"    {added}/{len(all_features)} written...")

    success = contours_layer.commitChanges()
    if success:
        print(f"  ✓ Committed {len(all_features)} features to {contours_layer.name()}")
    else:
        errors = contours_layer.commitErrors()
        print(f"  ✗ Commit failed: {errors}")
        contours_layer.rollBack()
        return

    elapsed = time.time() - t0
    print()
    print("=" * 60)
    print(f"  ✓ Elevation generation complete! ({elapsed:.1f}s)")
    print(f"    {len(all_features)} contour features written")
    print(f"    Elevation range: {e_min:.1f}m .. {e_max:.1f}m")
    print()
    print("  Next step: run export_planet.py to generate heightmaps")
    print("=" * 60)


# ── Run ─────────────────────────────────────────────────────────
generate_elevation()
