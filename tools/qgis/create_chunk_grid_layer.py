"""
QGIS tool: Create a vector layer showing all exported HEALPix chunk boundaries.

Run in the QGIS Python console:
    exec(open('tools/qgis/create_chunk_grid_layer.py').read())

For each chunk in assets/qgis/export/<planet>_chunks/base_<depth>/,
a polygon is drawn showing the exact boundary of that HEALPix tile.
Each feature is labelled with its pixel index and recipe filename
(e.g. "hp_n64_p24576").

The layer is named "<planet>_chunk_grid" and added to the QGIS project.
If the layer already exists it is replaced.

Parameters below can be overridden before exec()-ing the script.
"""

import os
import math
import numpy as np

# ── Parameters ──────────────────────────────────────────────────────────────
# Auto-detected from the project variable set by setup_planet_project.py.
# Override manually if needed.
_project = QgsProject.instance()
_proj_name = QgsExpressionContextUtils.projectScope(_project).variable("planet_name")
PLANET_NAME = str(_proj_name) if _proj_name else "tarsis_4"

EXPORT_DIR = "/datas/developpement/sources/DyingStar-game/DyingStar/assets/qgis/export"

# Number of edge samples used to trace each chunk boundary polygon.
# 8 gives smooth-enough curves; increase for higher fidelity at the poles.
EDGE_SAMPLES = 12
# ────────────────────────────────────────────────────────────────────────────

import sys
sys.path.insert(0, os.path.join(os.path.dirname(EXPORT_DIR), "../tools/qgis"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__) if "__file__" in dir() else ".", ""))
# Ensure healpix_utils is importable
_tools_dir = os.path.join(EXPORT_DIR, "../../tools/qgis")
if _tools_dir not in sys.path:
    sys.path.insert(0, os.path.normpath(_tools_dir))

from healpix_utils import face_xy_to_lonlat, nest2xy

# ── Find chunk directory ─────────────────────────────────────────────────────
chunks_dir = None
for depth in range(10, 0, -1):
    candidate = os.path.join(EXPORT_DIR, f"{PLANET_NAME}_chunks", f"base_{depth}")
    if os.path.isdir(candidate):
        chunks_dir = candidate
        break

if chunks_dir is None:
    print(f"  ✗ No chunk directory found for planet '{PLANET_NAME}' in {EXPORT_DIR}")
    raise SystemExit(1)

print(f"  Using chunk dir: {chunks_dir}")

# Collect all exported pixel indices and nside
recipe_files = sorted(f for f in os.listdir(chunks_dir) if f.endswith(".recipe.bin"))
if not recipe_files:
    print("  ✗ No .recipe.bin files found in chunk directory.")
    raise SystemExit(1)

# Parse nside and ipix from filename: hp_n<nside>_p<ipix>.recipe.bin
import re
_RE = re.compile(r"hp_n(\d+)_p(\d+)\.recipe\.bin")
pixels = []
nside = None
for fname in recipe_files:
    m = _RE.match(fname)
    if m:
        ns, ip = int(m.group(1)), int(m.group(2))
        if nside is None:
            nside = ns
        pixels.append(ip)

if not pixels:
    print("  ✗ Could not parse any pixel indices from recipe filenames.")
    raise SystemExit(1)

# Track which pixels actually have recipes (for attribute flag)
exported_set = set(pixels)

# Draw ALL nside² × 12 pixels, not just the exported subset
all_pixels = list(range(12 * nside * nside))
print(f"  Found {len(exported_set)} exported chunks, nside={nside}")
print(f"  Drawing all {len(all_pixels)} chunks (12 × {nside}² = {len(all_pixels)})")
pixels = all_pixels

# ── Build boundary polygon for one HEALPix pixel ────────────────────────────

def _pixel_boundary(nside, ipix, n_edge):
    """
    Return one or two rings (as lists of QgsPointXY) tracing the boundary of one
    HEALPix nested pixel in EPSG:4326.

    Pixels whose boundary crosses the antimeridian (lon ±180°) are split into
    two separate rings so QGIS renders them correctly instead of wrapping them
    across the globe.

    Returns a list of rings; each ring is a closed list of QgsPointXY.
    n_edge: number of sample points per edge (minimum 2 = corners only).
    """
    npface = nside * nside
    face   = ipix // npface
    local  = ipix %  npface
    ix, iy = nest2xy(local)

    t = np.linspace(0.0, 1.0, n_edge, endpoint=False)

    fx_bottom = ix + t
    fy_bottom = np.full_like(t, float(iy))
    fx_right  = np.full_like(t, float(ix + 1))
    fy_right  = iy + t
    fx_top    = ix + 1.0 - t
    fy_top    = np.full_like(t, float(iy + 1))
    fx_left   = np.full_like(t, float(ix))
    fy_left   = iy + 1.0 - t

    fx_all = np.concatenate([fx_bottom, fx_right, fx_top, fx_left])
    fy_all = np.concatenate([fy_bottom, fy_right, fy_top, fy_left])

    pts = []  # list of (lon, lat) floats
    for fx, fy in zip(fx_all, fy_all):
        lon, lat = face_xy_to_lonlat(face, float(fx), float(fy), nside)
        pts.append((lon, lat))
    pts.append(pts[0])  # close

    # ── Antimeridian split ────────────────────────────────────────────────
    # Detect whether any edge jumps >180° in longitude (antimeridian crossing).
    # If so, shift the entire ring to [0, 360) and then re-split into two
    # polygons at lon=180.
    has_jump = any(abs(pts[i+1][0] - pts[i][0]) > 180.0
                   for i in range(len(pts) - 1))

    if not has_jump:
        return [[QgsPointXY(lon, lat) for lon, lat in pts]]

    # Normalise all longitudes to [0, 360)
    norm = [(lon % 360.0, lat) for lon, lat in pts]

    # Split into west part (lon < 180, shift to negative) and east part (lon > 180)
    west, east = [], []
    for lon360, lat in norm:
        if lon360 <= 180.0:
            west.append(QgsPointXY(lon360, lat))
        else:
            east.append(QgsPointXY(lon360 - 360.0, lat))  # shift to negative range

    rings = []
    if len(west) >= 3:
        west.append(west[0])
        rings.append(west)
    if len(east) >= 3:
        east.append(east[0])
        rings.append(east)
    # Fallback: if splitting produced nothing usable, return original
    if not rings:
        rings = [[QgsPointXY(lon, lat) for lon, lat in pts]]
    return rings


# ── Create / replace the layer ───────────────────────────────────────────────
LAYER_NAME = f"{PLANET_NAME}_chunk_grid"

# Remove existing layer with the same name
for old in QgsProject.instance().mapLayersByName(LAYER_NAME):
    QgsProject.instance().removeMapLayer(old.id())

layer = QgsVectorLayer("Polygon?crs=EPSG:4326", LAYER_NAME, "memory")
provider = layer.dataProvider()

provider.addAttributes([
    QgsField("ipix",     QVariant.Int,    "integer"),
    QgsField("nside",    QVariant.Int,    "integer"),
    QgsField("label",    QVariant.String, "string", 30),
    QgsField("face",     QVariant.Int,    "integer"),
    QgsField("exported", QVariant.Int,    "integer"),  # 1 = has recipe on disk
])
layer.updateFields()

# ── Populate features ────────────────────────────────────────────────────────
features = []
npface = nside * nside
BATCH = 500

for i, ipix in enumerate(pixels):
    try:
        rings = _pixel_boundary(nside, ipix, EDGE_SAMPLES)
    except Exception as e:
        print(f"    ⚠ Skipping ipix={ipix}: {e}")
        continue

    for ring in rings:
        geom = QgsGeometry.fromPolygonXY([ring])
        feat = QgsFeature()
        feat.setGeometry(geom)
        feat.setAttributes([
            ipix,
            nside,
            f"hp_n{nside}_p{ipix}",
            ipix // npface,
            1 if ipix in exported_set else 0,
        ])
        features.append(feat)

    if len(features) >= BATCH:
        provider.addFeatures(features)
        features.clear()

if features:
    provider.addFeatures(features)

layer.updateExtents()

# ── Style: categorised by "exported" field ───────────────────────────────────
# exported=1 → blue outline (has recipe), exported=0 → grey outline (no recipe)
def _fill_symbol(outline_color, outline_width="0.2"):
    return QgsFillSymbol.createSimple({
        "color":         "0,0,0,0",
        "outline_color": outline_color,
        "outline_width": outline_width,
    })

cat_exported = QgsRendererCategory(
    1, _fill_symbol("0,120,220", "0.3"), "Exported (has recipe)")
cat_missing  = QgsRendererCategory(
    0, _fill_symbol("160,160,160", "0.15"), "Not exported")

renderer = QgsCategorizedSymbolRenderer("exported", [cat_exported, cat_missing])
layer.setRenderer(renderer)

# Labels
label_settings = QgsPalLayerSettings()
label_settings.fieldName = "label"
label_settings.enabled   = True

text_format = QgsTextFormat()
text_format.setSize(6)
text_format.setSizeUnit(QgsUnitTypes.RenderPoints)

buf = QgsTextBufferSettings()
buf.setEnabled(True)
buf.setSize(0.5)
buf.setColor(QColor("white"))
text_format.setBuffer(buf)
label_settings.setFormat(text_format)

layer.setLabeling(QgsVectorLayerSimpleLabeling(label_settings))
layer.setLabelsEnabled(True)

# ── Add to project ───────────────────────────────────────────────────────────
QgsProject.instance().addMapLayer(layer)

print(f"  ✓ Layer '{LAYER_NAME}' created with {layer.featureCount()} chunk polygons.")
print(f"    Labels show 'hp_n{nside}_p<ipix>'.  Zoom in to see individual chunks.")
