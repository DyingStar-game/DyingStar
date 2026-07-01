"""
export_elevation.py — QGIS → Godot per-chunk elevation export (standard mesh pipeline)
======================================================================================

Elevation-ONLY exporter. Produces one heightmap file per HEALPix chunk so the
standard mesh terrain (scenes/planet/planet_terrain.gd) can displace its sphere
chunks directly from QGIS contour data — no recipes, no voxels.

Pipeline
--------
1. Read the contour / elevation line layer (field: elev/elevation/height/z/alt).
   Contours are drawn at 50 m intervals in EPSG:4326 (lon/lat degrees).
2. Interpolate a single global equirectangular elevation raster (reuses the fast
   rasterize→fill→upsample interpolator in export/planet/heightmap.py).
3. For each of 12·nside² HEALPix pixels, sample a (TILE_RES × TILE_RES) grid of
   directions covering that pixel and bilinearly read the global raster.
4. Write each tile as a RAW float32 blob (.r32), values normalized to
   [0,1] over [ELEV_MIN, ELEV_MAX].

Why .r32 (raw float32) instead of 16-bit PNG?
    Godot's PNG loader downsamples 16-bit greyscale to 8-bit on import (256
    elevation steps → visible terracing). A raw float32 blob is loaded losslessly
    via Image.create_from_data(..., Image.FORMAT_RF, bytes) — exact, no importer.

Round-trip with Godot
---------------------
    Godot decodes height as:  elev = pixel.r * max_height + height_offset
    so the manifest exports:  height_offset = ELEV_MIN
                              max_height    = ELEV_MAX - ELEV_MIN
    Set these on the PlanetData resource (or let it read manifest.json).

Run from the QGIS Python Console:
    exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/qgis/export_elevation.py').read())
"""
import os
import sys
import json
import math
import numpy as np

# ── Make tools/ importable so we can reuse healpix_utils + the interpolator ──
_tools_dir = os.path.dirname(os.path.abspath(__file__))
if _tools_dir not in sys.path:
    sys.path.insert(0, _tools_dir)

import healpix_utils as hpx
from export.planet.heightmap import generate_heightmap_from_contours

from qgis.core import (
    QgsProject,
    QgsVectorLayer,
    QgsExpressionContextUtils,
)

# ============================================================
# CONFIGURATION — edit for your planet
# ============================================================
_project = QgsProject.instance()
_proj_planet_name = QgsExpressionContextUtils.projectScope(_project).variable("planet_name")
_proj_planet_radius = QgsExpressionContextUtils.projectScope(_project).variable("planet_radius_m")

PLANET_NAME = str(_proj_planet_name) if _proj_planet_name else "tarsis_5"
# Planet radius in metres (sea-level surface). New value: 6356 km.
PLANET_RADIUS = int(_proj_planet_radius) if _proj_planet_radius else 6_356_000

EXPORT_DIR = os.path.expanduser(
    "/datas/developpement/sources/DyingStar-game/DyingStar/assets/qgis/.export"
)

# HEALPix tiling. nside=64 → 12·64² = 49152 chunks (chunk_export_depth=6).
NSIDE = 64
# Samples per chunk edge. 25 → ~4 km spacing on a 6356 km planet (broad shape;
# fine detail comes from the quadtree mesh interpolating between samples).
TILE_RES = 25

# Global interpolation raster (equirectangular, width = 2 × height).
HEIGHTMAP_SIZE = (4096, 2048)

# Elevation range for normalization. None = auto-detect from contour data.
ELEV_MIN = None
ELEV_MAX = None

# Contour field names accepted, in priority order.
_ELEV_FIELDS = ("elev", "elevation", "height", "z", "alt")


# ============================================================
# Helpers
# ============================================================
def _memlog(label, *extra):
    """No-op progress logger passed to the shared interpolator."""
    if extra:
        print(f"  · {label}: {' '.join(str(e) for e in extra)}")
    else:
        print(f"  · {label}")


def find_layers_by_keyword(keyword):
    """Return project layers whose name contains *keyword* (case-insensitive)."""
    kw = keyword.lower()
    return [l for l in QgsProject.instance().mapLayers().values()
            if kw in l.name().lower()]


def _find_contour_layer():
    layers = find_layers_by_keyword("contour") + find_layers_by_keyword("elevation")
    for l in layers:
        if isinstance(l, QgsVectorLayer):
            return l
    return None


def _elev_field(layer):
    for field in layer.fields():
        if field.name().lower() in _ELEV_FIELDS:
            return field.name()
    return None


def scan_elevation_range(layer, field):
    """Auto-detect [ELEV_MIN, ELEV_MAX] from the contour layer if not set."""
    global ELEV_MIN, ELEV_MAX
    if ELEV_MIN is not None and ELEV_MAX is not None:
        print(f"  Using configured elevation range: [{ELEV_MIN}, {ELEV_MAX}]m")
        return
    vals = []
    for feat in layer.getFeatures():
        v = feat[field]
        if v is None:
            continue
        try:
            e = float(v)
        except (ValueError, TypeError):
            continue
        geom = feat.geometry()
        if geom and not geom.isNull():
            c = geom.centroid().asPoint()
            if abs(c.x()) < 0.01 and abs(c.y()) < 0.01 and e == 0.0:
                continue  # skip setup stub feature at (0,0)
        vals.append(e)
    if vals:
        cmin, cmax = min(vals), max(vals)
        ELEV_MIN = 0.0 if cmin >= 0 else cmin
        ELEV_MAX = cmax if cmax > ELEV_MIN else ELEV_MIN + 1.0
        print(f"  ✓ Auto elevation range from {len(vals)} contour values: "
              f"[{ELEV_MIN}, {ELEV_MAX}]m")
    else:
        ELEV_MIN, ELEV_MAX = 0.0, 1000.0
        print(f"  ⚠ No contour values — default range [{ELEV_MIN}, {ELEV_MAX}]m")


def _read_global_raster(path, size):
    """Read the interpolated global heightmap back as a (H, W) float32 array."""
    w, h = size
    if path.endswith(".npy"):
        arr = np.load(path)
    else:
        from osgeo import gdal
        ds = gdal.Open(path)
        arr = ds.GetRasterBand(1).ReadAsArray().astype(np.float32)
        ds = None
    if arr.shape != (h, w):
        print(f"  ⚠ Raster shape {arr.shape} != expected {(h, w)}; using actual.")
    return arr


def _sample_equirect_bilinear(raster, lon, lat):
    """
    Bilinearly sample an equirectangular raster (origin lon=-180, lat=+90) at
    arrays of (lon, lat) in degrees. Returns an array of the same shape.
    """
    h, w = raster.shape
    col = (lon + 180.0) / 360.0 * w - 0.5
    row = (90.0 - lat) / 180.0 * h - 0.5

    # Longitude wraps; latitude clamps.
    x0 = np.floor(col).astype(np.int64)
    y0 = np.floor(row).astype(np.int64)
    fx = col - x0
    fy = row - y0
    x0w = np.mod(x0, w)
    x1w = np.mod(x0 + 1, w)
    y0c = np.clip(y0, 0, h - 1)
    y1c = np.clip(y0 + 1, 0, h - 1)

    a00 = raster[y0c, x0w]
    a10 = raster[y0c, x1w]
    a01 = raster[y1c, x0w]
    a11 = raster[y1c, x1w]
    return (a00 * (1 - fx) * (1 - fy) + a10 * fx * (1 - fy)
            + a01 * (1 - fx) * fy + a11 * fx * fy)


# ============================================================
# Main export
# ============================================================
def run_export():
    print("=" * 64)
    print(f"  export_elevation: planet='{PLANET_NAME}' radius={PLANET_RADIUS}m "
          f"nside={NSIDE} tile_res={TILE_RES}")
    print("=" * 64)

    layer = _find_contour_layer()
    if layer is None:
        print("  ✗ No contour/elevation vector layer found. Aborting.")
        return
    field = _elev_field(layer)
    if not field:
        print(f"  ✗ No elevation field in '{layer.name()}'. "
              f"Expected one of {_ELEV_FIELDS}.")
        return
    print(f"  Contour layer: '{layer.name()}'  field: '{field}'")

    os.makedirs(EXPORT_DIR, exist_ok=True)
    scan_elevation_range(layer, field)
    elev_range = ELEV_MAX - ELEV_MIN

    # ── Step 1: global interpolated raster (reuse shared interpolator) ──
    print("  Building global elevation raster…")
    raster_path = generate_heightmap_from_contours(
        PLANET_NAME, EXPORT_DIR, HEIGHTMAP_SIZE,
        find_layers_by_keyword, _memlog,
    )
    if raster_path is None:
        print("  ✗ Global raster interpolation failed. Aborting.")
        return
    raster = _read_global_raster(raster_path, HEIGHTMAP_SIZE)
    print(f"  Global raster: {raster.shape}  range "
          f"[{np.nanmin(raster):.1f}, {np.nanmax(raster):.1f}]m")

    # ── Step 2: per-chunk tiles ──
    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    os.makedirs(chunks_dir, exist_ok=True)
    npix = 12 * NSIDE * NSIDE
    npface = NSIDE * NSIDE
    print(f"  Writing {npix} chunk tiles ({TILE_RES}×{TILE_RES} float32) → {chunks_dir}")

    for face in range(12):
        os.makedirs(os.path.join(chunks_dir, f"face_{face}"), exist_ok=True)

    written = 0
    for ipix in range(npix):
        lon_grid, lat_grid = hpx.get_tile_grid_lonlat(NSIDE, ipix, TILE_RES)
        elev = _sample_equirect_bilinear(raster, lon_grid, lat_grid)
        # Normalize to [0,1] over [ELEV_MIN, ELEV_MAX]. Values outside the range
        # are kept (FORMAT_RF is unclamped) so future features can exceed it.
        norm = ((elev - ELEV_MIN) / elev_range).astype(np.float32)
        face = ipix // npface
        out = os.path.join(chunks_dir, f"face_{face}", f"f{ipix}.r32")
        norm.tofile(out)  # C-order (row=fy, col=fx) — matches Godot FORMAT_RF
        written += 1
        if written % 4096 == 0:
            print(f"    {written}/{npix} tiles…")

    # ── Step 3: manifest ──
    depth = int(round(math.log2(NSIDE)))
    manifest = {
        "planet_name": PLANET_NAME,
        "radius": float(PLANET_RADIUS),
        "nside": NSIDE,
        "chunk_export_depth": depth,
        "tile_res": TILE_RES,
        "format": "r32_f32_normalized",   # raw float32, row-major, normalized [0,1]
        "layout": "face_{face}/f{ipix}.r32",
        "elev_min": float(ELEV_MIN),
        "elev_max": float(ELEV_MAX),
        # Godot PlanetData round-trip: elev = pixel.r * max_height + height_offset
        "height_offset": float(ELEV_MIN),
        "max_height": float(elev_range),
        "count": npix,
    }
    manifest_path = os.path.join(chunks_dir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print("=" * 64)
    print(f"  ✓ Done. {written} tiles + manifest.json")
    print(f"    chunks_dir : {chunks_dir}")
    print(f"    radius     : {PLANET_RADIUS} m")
    print(f"    height_offset={ELEV_MIN}  max_height={elev_range}")
    print(f"    → Set PlanetData.chunk_heightmaps_dir to the chunks dir "
          f"(or load manifest.json).")
    print("=" * 64)


run_export()
