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
3. For each pyramid level nside ∈ {NSIDE_MIN, …, NSIDE/2, NSIDE}, and each of
   its 12·nside² HEALPix pixels, sample a (TILE_RES × TILE_RES) grid of
   directions covering that pixel and bilinearly read the global raster.
4. Stream every tile (raw float32, normalized to [0,1] over
   [ELEV_MIN, ELEV_MAX]) into a single dense archive
   {planet}_chunks/heights.pack (DSHP v1, spec below), read at runtime by
   scenes/planet/height_pack.gd. One file instead of ~65k tiny .r32 files:
   fast tar/rsync/Godot export, O(1) offsets, no index.
   Set WRITE_LOOSE_TILES = True to ALSO write the legacy
   n{nside}/face_{face}/f{ipix}.r32 tree (debug / diffing only — the
   runtime reads exclusively from heights.pack).
   The pyramid lets far LODs read one coarse tile per chunk instead of
   point-sampling many fine tiles (no aliasing, cheap whole-planet view).

DSHP v1 on-disk format (little-endian) — authoritative spec
-----------------------------------------------------------
    0   magic       "DSHP" (4 B)
    4   version     u32 = 1
    8   tile_res    u32     samples per tile edge (tile = tile_res² float32)
    12  nside_min   u32     coarsest pyramid level
    16  nside_max   u32     finest pyramid level (levels = all powers of two between)
    20  flags       u32     reserved, 0
    24  blob_start  u32     absolute offset of the tile blob
    28  json_len    u32
    32  manifest    json_len B  (verbatim manifest.json, UTF-8)
    …   padding to blob_start (16-byte aligned)
    blob: for nside = nside_min, 2·nside_min, …, nside_max (ascending):
              tiles f0 … f(12·nside²−1), each tile_res²·4 B raw float32 LE

Every tile is fixed-size and every ipix exists at every level, so the reader
needs no index:  offset(nside, ipix) = blob_start + level_base[nside] + ipix·tile_size

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
import struct
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
    "/datas/developpement/sources/DyingStar-game/DyingStar/assets/qgis/export"
)

# HEALPix tiling. nside=64 → 12·64² = 49152 chunks (chunk_export_depth=6).
# This is the FINEST pyramid level (LOD0). Coarser levels down to NSIDE_MIN are
# baked too, so far/whole-planet LODs read a single coarse tile instead of
# point-sampling many fine ones (no aliasing, no 49k-tile fetch from orbit).
NSIDE = 64
# Coarsest pyramid level to bake. 1 → the 12 HEALPix base faces (whole-planet view).
# Levels baked: NSIDE, NSIDE/2, … , NSIDE_MIN (all powers of two).
NSIDE_MIN = 1
# Samples per chunk edge. 25 → ~4 km spacing on a 6356 km planet (broad shape;
# fine detail comes from the quadtree mesh interpolating between samples).
TILE_RES = 25

# Also write the legacy loose-tile tree (n{nside}/face_{face}/f{ipix}.r32) next
# to heights.pack. Off by default: the pack alone is what the runtime reads,
# and ~65k tiny files per planet are exactly what this format eliminates.
WRITE_LOOSE_TILES = False

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
_DSHP_MAGIC = b"DSHP"
_DSHP_VERSION = 1
_DSHP_ALIGN = 16


def build_header(manifest_bytes, tile_res, nside_min, nside_max):
    """DSHP v1 fixed header + embedded manifest, padded to _DSHP_ALIGN."""
    raw_len = 32 + len(manifest_bytes)
    blob_start = (raw_len + _DSHP_ALIGN - 1) // _DSHP_ALIGN * _DSHP_ALIGN
    head = struct.pack("<4s6I", _DSHP_MAGIC, _DSHP_VERSION, tile_res,
                       nside_min, nside_max, 0, blob_start)
    head += struct.pack("<I", len(manifest_bytes)) + manifest_bytes
    return head + b"\x00" * (blob_start - raw_len)


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
    global ELEV_MIN, ELEV_MAX
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
        # No elevation field yet → nothing to displace. Export a FLAT planet
        # rather than aborting, so planets still being authored can be built.
        print(f"  ⚠ No elevation field in '{layer.name()}' "
              f"(expected one of {_ELEV_FIELDS}) — exporting FLAT terrain.")
    else:
        print(f"  Contour layer: '{layer.name()}'  field: '{field}'")

    os.makedirs(EXPORT_DIR, exist_ok=True)
    if field:
        scan_elevation_range(layer, field)
    else:
        if ELEV_MIN is None:
            ELEV_MIN = 0.0
        if ELEV_MAX is None:
            ELEV_MAX = 1000.0
        print(f"  Flat terrain range: [{ELEV_MIN}, {ELEV_MAX}]m")
    elev_range = ELEV_MAX - ELEV_MIN

    # ── Step 1: global interpolated raster (reuse shared interpolator) ──
    # If the contour layer has no (or too few) lines yet, the interpolator
    # returns None; we then export a FLAT raster (elev = ELEV_MIN everywhere)
    # so the planet still builds as a smooth sea-level sphere.
    raster_path = None
    if field:
        print("  Building global elevation raster…")
        raster_path = generate_heightmap_from_contours(
            PLANET_NAME, EXPORT_DIR, HEIGHTMAP_SIZE,
            find_layers_by_keyword, _memlog,
        )
    if raster_path is None:
        w, h = HEIGHTMAP_SIZE
        raster = np.full((h, w), ELEV_MIN, dtype=np.float32)
        print(f"  ⚠ No usable contour data — FLAT raster {raster.shape} "
              f"at elev={ELEV_MIN}m (whole planet at sea level).")
    else:
        raster = _read_global_raster(raster_path, HEIGHTMAP_SIZE)
        print(f"  Global raster: {raster.shape}  range "
              f"[{np.nanmin(raster):.1f}, {np.nanmax(raster):.1f}]m")

    # ── Step 2: manifest (written first — it is embedded in heights.pack) ──
    chunks_dir = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks")
    os.makedirs(chunks_dir, exist_ok=True)

    # Pyramid levels: NSIDE_MIN, … , NSIDE/2, NSIDE (ascending powers of two —
    # the DSHP blob layout requires coarse levels first).
    levels = []
    ns = max(NSIDE_MIN, 1)
    while ns <= NSIDE:
        levels.append(ns)
        ns *= 2
    total_tiles = sum(12 * n * n for n in levels)

    depth = int(round(math.log2(NSIDE)))
    manifest = {
        "planet_name": PLANET_NAME,
        "radius": float(PLANET_RADIUS),
        "nside": NSIDE,                    # finest level (== nside_max)
        "chunk_export_depth": depth,       # log2(finest nside)
        "tile_res": TILE_RES,
        "format": "r32_f32_normalized",    # raw float32, row-major, normalized [0,1]
        # Pyramid descriptor. Runtime reads level n{nside} for a chunk whose own
        # nside is clamp(chunk_nside, nside_min, nside_max).
        "pyramid": True,
        "nside_min": int(min(levels)),
        "nside_max": int(max(levels)),
        "layout": "n{nside}/face_{face}/f{ipix}.r32",
        "elev_min": float(ELEV_MIN),
        "elev_max": float(ELEV_MAX),
        # Godot PlanetData round-trip: elev = pixel.r * max_height + height_offset
        "height_offset": float(ELEV_MIN),
        "max_height": float(elev_range),
        "count": total_tiles,
    }
    manifest["packed"] = True
    manifest["pack_file"] = "heights.pack"
    manifest_bytes = json.dumps(manifest, indent=2).encode("utf-8")
    manifest_path = os.path.join(chunks_dir, "manifest.json")
    with open(manifest_path, "wb") as f:
        f.write(manifest_bytes)

    # ── Step 3: stream all tiles into one dense heights.pack (DSHP v1) ──
    # Tile order matches height_pack.gd: levels ascending, ipix ascending, each
    # tile TILE_RES²·4 bytes → offset(nside, ipix) is pure arithmetic at runtime.
    # Each level independently samples the SAME smooth global raster, so all
    # levels agree on the underlying surface (minimal LOD popping) while a coarse
    # level's tile already represents the average shape over its larger footprint.
    pack_path = os.path.join(chunks_dir, "heights.pack")
    tmp_path = pack_path + ".tmp"
    print(f"  Writing pyramid levels {levels} = {total_tiles} tiles "
          f"({TILE_RES}×{TILE_RES} float32) → {pack_path}")

    written = 0
    with open(tmp_path, "wb") as out:
        out.write(build_header(manifest_bytes, TILE_RES,
                               int(min(levels)), int(max(levels))))
        for level_nside in levels:
            npix = 12 * level_nside * level_nside
            npface = level_nside * level_nside
            if WRITE_LOOSE_TILES:
                level_dir = os.path.join(chunks_dir, f"n{level_nside}")
                for face in range(12):
                    os.makedirs(os.path.join(level_dir, f"face_{face}"),
                                exist_ok=True)
            for ipix in range(npix):
                lon_grid, lat_grid = hpx.get_tile_grid_lonlat(
                    level_nside, ipix, TILE_RES)
                elev = _sample_equirect_bilinear(raster, lon_grid, lat_grid)
                # Normalize to [0,1] over [ELEV_MIN, ELEV_MAX]. Values outside the
                # range are kept (FORMAT_RF is unclamped) so future features can
                # exceed it.
                norm = ((elev - ELEV_MIN) / elev_range).astype(np.float32)
                # C-order (row=fy, col=fx) — matches Godot FORMAT_RF
                out.write(norm.tobytes())
                if WRITE_LOOSE_TILES:
                    face = ipix // npface
                    norm.tofile(os.path.join(
                        level_dir, f"face_{face}", f"f{ipix}.r32"))
                written += 1
                if written % 8192 == 0:
                    print(f"    {written}/{total_tiles} tiles…")
            print(f"    · level n{level_nside}: {npix} tiles")
    os.replace(tmp_path, pack_path)
    pack_mb = os.path.getsize(pack_path) / (1 << 20)

    print("=" * 64)
    print(f"  ✓ Done. {written} tiles ({len(levels)} levels) → "
          f"heights.pack ({pack_mb:.1f} MB) + manifest.json")
    print(f"    chunks_dir : {chunks_dir}")
    print(f"    radius     : {PLANET_RADIUS} m")
    print(f"    pyramid    : n{min(levels)} … n{max(levels)}")
    print(f"    height_offset={ELEV_MIN}  max_height={elev_range}")
    print(f"    → Set PlanetData.chunk_heightmaps_dir to the chunks dir "
          f"(or load manifest.json).")
    print("=" * 64)


run_export()
