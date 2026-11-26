"""
Preview the procedural mountains in QGIS: elevation contours (+ a hillshade).
=============================================================================

The `mountain_range` polygons and `ridge` lines only say WHERE the mountains are
and in which STYLE — Godot generates their relief (scenes/planet/mountain_relief.gd).
So in QGIS nobody sees how high a massif goes, which makes placing a road or a
village across it guesswork. This script evaluates the same relief
(export/planet/mountain_preview.py, pinned to Godot's values by
test/unit/test_mountain_preview_py.py) and draws it:

    Mountain preview (group, at the top of the layer tree)
      ├─ Mountain contours      lines every CONTOUR_INTERVAL_M, every INDEX_EVERY-th
      │                         thicker and labelled; fields elev_m, major, massif
      └─ Mountain relief N      hillshade of each group of overlapping features

By default only the part of the planet shown in the map canvas is computed
(ONLY_CANVAS_EXTENT): zoom on the area you work on, then run.

Read-only: it changes neither the mountain layers nor the pack. Re-run it after
moving or retuning a massif — the previous preview is replaced.

What the numbers are
--------------------
    ADD_GROUND_ELEVATION = False (default): the height the mountains ADD above the
    ground, in metres — "+250" is 250 m above the plain under it.
    ADD_GROUND_ELEVATION = True: absolute altitude = <planet>_heightmap.tif (written
    by export_elevation.py, a coarse global raster: ~2–5 km per pixel) + mountains.

    The grid pitch is SAMPLE_SPACING_M: noise details finer than half of it are left
    out, as the game does on a terrain LOD of that pitch. 50 m shows every form a
    road cares about; lower it for a close look at a pass (cost grows as 1/pitch²).

Not included: volcanoes and rocky terrain (their relief also stacks in the game),
and features crossing the ±180° meridian.

Outputs (next to the .qgz, in mountain_preview/; in the QGIS temp folder when the
project is not saved yet):
    <planet>_mountain_preview_<stamp>.gpkg        the contours
    <planet>_mountain_relief_<stamp>_<n>.tif      the relief, metres, EPSG:4326

Run from QGIS: DyingStar ▸ Roads ▸ Mountain preview (the plugin asks the options and computes in
a background task). From the Python console:
    import preview_mountain_contours as p; p.run(spacing_m=50, add_ground=True)
"""

import datetime
import glob
import json
import math
import os
import sys
import tempfile
import time

from qgis.core import (
    Qgis,
    QgsBilinearRasterResampler,
    QgsCategorizedSymbolRenderer,
    QgsCoordinateReferenceSystem,
    QgsCoordinateTransform,
    QgsHillshadeRenderer,
    QgsLineSymbol,
    QgsPalLayerSettings,
    QgsProject,
    QgsRasterDataProvider,
    QgsRasterLayer,
    QgsRendererCategory,
    QgsTextBufferSettings,
    QgsTextFormat,
    QgsVectorLayer,
    QgsVectorLayerSimpleLabeling,
)
from qgis.PyQt.QtGui import QColor

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import numpy as np                                        # noqa: E402
from osgeo import gdal, ogr, osr                          # noqa: E402

import ds_project                                         # noqa: E402
import link_modifiers                                     # noqa: E402
from export.planet import mountain_preview as mp          # noqa: E402

# ============================================================
# CONFIGURATION
# ============================================================
# The planet of the open project, read by _configure() at each run (ds_project.py).
PLANET_NAME = None
PLANET_RADIUS = None

# The options below are the defaults; run(...) / prepare(...) take each of them as a keyword
# (see OPTIONS).
# Height between two contour lines (m).
CONTOUR_INTERVAL_M = 50.0
# Every INDEX_EVERY-th line is thicker and labelled (5 × 50 m = every 250 m).
INDEX_EVERY = 5
# Grid pitch (m): finer = more detail and slower (time ∝ 1/pitch²).
SAMPLE_SPACING_M = 50.0
# Only the part of the planet shown in the map canvas: zoom on the area you work on,
# then run. False = every feature in full — a set of massifs spanning thousands of km
# then only fits MAX_SAMPLES at a pitch of kilometres (angular contours, no detail).
ONLY_CANVAS_EXTENT = True
# Ceiling of samples per group of overlapping features: past it the pitch grows
# (4 M = a 100 km square at 50 m).
MAX_SAMPLES = 4_000_000
# False: height ADDED by the mountains. True: + the base terrain (<planet>_heightmap.tif).
ADD_GROUND_ELEVATION = False
# Also add a hillshade of the relief under the contours.
ADD_RELIEF_RASTER = True
# Only the features selected in the mountain_range / ridge layers.
ONLY_SELECTED = False

GROUP_NAME = "Mountain preview"
_PREVIEW_TAG = "ds_preview"

#: keyword of run() / prepare() -> the module option it sets.
OPTIONS = {
    "interval_m": "CONTOUR_INTERVAL_M",
    "index_every": "INDEX_EVERY",
    "spacing_m": "SAMPLE_SPACING_M",
    "only_canvas": "ONLY_CANVAS_EXTENT",
    "max_samples": "MAX_SAMPLES",
    "add_ground": "ADD_GROUND_ELEVATION",
    "add_relief": "ADD_RELIEF_RASTER",
    "only_selected": "ONLY_SELECTED",
}


def _configure(options):
    global PLANET_NAME, PLANET_RADIUS
    planet = ds_project.planet()
    PLANET_NAME = planet.name
    PLANET_RADIUS = int(planet.radius_m)
    for key, value in options.items():
        if key not in OPTIONS:
            raise TypeError(f"unknown option {key!r} (one of {', '.join(OPTIONS)})")
        globals()[OPTIONS[key]] = value


# ============================================================
# Reading the features (same rules as export_mountains.py)
# ============================================================
def _is_null(value):
    if value is None:
        return True
    if hasattr(value, "isNull"):
        return bool(value.isNull())
    return str(value) == "NULL"


def _plain(value):
    if isinstance(value, (bool, int, float, str)):
        return value
    try:
        return float(value)
    except (TypeError, ValueError):
        return str(value)


def find_layers(kind, geom_type):
    """Project layers whose `ds_kind` custom property is [kind]."""
    out = []
    for layer in QgsProject.instance().mapLayers().values():
        if not isinstance(layer, QgsVectorLayer) or layer.geometryType() != geom_type:
            continue
        if str(layer.customProperty("ds_kind", "") or "") == kind:
            out.append(layer)
    return out


def _fields_of(feat):
    props = {}
    for field in feat.fields():
        name = field.name()
        if name in ("fid", "id", "last_updated"):
            continue
        value = feat[name]
        if not _is_null(value):
            props[name] = _plain(value)
    return props


def _coords(geom, single, multi):
    if geom is None or geom.isEmpty():
        return []
    raw = json.loads(geom.asJson())
    if raw.get("type") == single:
        return [raw.get("coordinates", [])]
    if raw.get("type") == multi:
        return raw.get("coordinates", [])
    return []


def _features(layer):
    return layer.getSelectedFeatures() if ONLY_SELECTED else layer.getFeatures()


def collect_features():
    feats = []
    for layer in find_layers("mountain_range", Qgis.GeometryType.Polygon):
        n = 0
        for feat in _features(layer):
            props = _fields_of(feat)
            for poly in _coords(feat.geometry(), "Polygon", "MultiPolygon"):
                if not poly:
                    continue
                ring = [(float(p[0]), float(p[1])) for p in poly[0]]
                if len(ring) > 1 and ring[0] == ring[-1]:
                    ring.pop()
                if len(ring) >= 3:
                    feats.append(mp.prepare_zone(ring, props))
                    n += 1
        print(f"  {layer.name():<32} {n} range(s)")
    for layer in find_layers("ridge", Qgis.GeometryType.Line):
        n = 0
        for feat in _features(layer):
            props = _fields_of(feat)
            for part in _coords(feat.geometry(), "LineString", "MultiLineString"):
                if len(part) >= 2:
                    feats.append(mp.prepare_ridge(part, props, PLANET_RADIUS))
                    n += 1
        print(f"  {layer.name():<32} {n} ridge(s)")
    return feats


# ============================================================
# Output files and the layer tree
# ============================================================
def _output_dir():
    home = QgsProject.instance().absolutePath()
    base = os.path.join(home, "mountain_preview") if home else \
        os.path.join(tempfile.gettempdir(), "ds_mountain_preview")
    os.makedirs(base, exist_ok=True)
    return base


def _drop_previous(out_dir):
    """Remove the previous preview's layers, then its files — the layers first, or
    QGIS keeps the files open (Windows refuses to delete them). Files still locked
    are left for the next run: every run writes new, stamped names."""
    root = QgsProject.instance().layerTreeRoot()
    for layer in list(QgsProject.instance().mapLayers().values()):
        if layer.customProperty(_PREVIEW_TAG, ""):
            QgsProject.instance().removeMapLayer(layer.id())
    group = root.findGroup(GROUP_NAME)
    if group is not None:
        root.removeChildNode(group)
    for pattern in (f"{PLANET_NAME}_mountain_preview_*.gpkg*", f"{PLANET_NAME}_mountain_relief_*.tif*"):
        for path in glob.glob(os.path.join(out_dir, pattern)):
            try:
                os.remove(path)
            except OSError:
                pass


def _canvas_box():
    """The map canvas extent as a lon/lat box, None outside the QGIS GUI."""
    try:
        from qgis.utils import iface
        canvas = iface.mapCanvas()
    except Exception:
        return None
    ext = canvas.extent()
    crs = canvas.mapSettings().destinationCrs()
    wgs = QgsCoordinateReferenceSystem("EPSG:4326")
    if crs != wgs:
        ext = QgsCoordinateTransform(crs, wgs, QgsProject.instance()).transformBoundingBox(ext)
    return (ext.xMinimum(), ext.xMaximum(), ext.yMinimum(), ext.yMaximum())


def _wgs84():
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(4326)
    srs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    return srs


def _mem_raster(grid, lons, lats):
    """A GDAL in-memory raster of [grid] whose pixel CENTRES are the samples."""
    dlon = float(lons[1] - lons[0]) if len(lons) > 1 else 1e-3
    dlat = float(lats[0] - lats[1]) if len(lats) > 1 else 1e-3
    ds = gdal.GetDriverByName("MEM").Create("", grid.shape[1], grid.shape[0], 1, gdal.GDT_Float32)
    ds.SetGeoTransform((float(lons[0]) - dlon * 0.5, dlon, 0.0, float(lats[0]) + dlat * 0.5, 0.0, -dlat))
    ds.SetProjection(_wgs84().ExportToWkt())
    ds.GetRasterBand(1).WriteArray(grid.astype(np.float32))
    return ds


def _levels(vmin, vmax):
    """Contour levels inside (vmin, vmax]. 0 is left out of a relative preview:
    the plain around a massif is exactly 0 and GDAL would trace its outline."""
    step = CONTOUR_INTERVAL_M
    first = math.floor(vmin / step) * step + step
    levels = []
    v = first
    while v <= vmax:
        if ADD_GROUND_ELEVATION or abs(v) > 1e-6:
            levels.append(float(v))
        v += step
    return levels


def _scratch_layer():
    """An in-memory OGR layer GDAL traces one group's contours into ("Memory"
    before GDAL 3.11, merged into "MEM" since)."""
    for name in ("Memory", "MEM"):
        drv = ogr.GetDriverByName(name)
        mem = drv.CreateDataSource("contours") if drv is not None else None
        if mem is not None:
            lyr = mem.CreateLayer("contours", _wgs84(), ogr.wkbLineString)
            lyr.CreateField(ogr.FieldDefn("id", ogr.OFTInteger))
            lyr.CreateField(ogr.FieldDefn("elev_m", ogr.OFTReal))
            return mem, lyr
    raise RuntimeError("no in-memory OGR driver (Memory / MEM)")


def _add_contours(src, levels, ds, out_lyr, names):
    """Trace [levels] of the raster [src] and append them to [out_lyr] with their
    `major` / `massif` fields. Returns the number of lines added."""
    if not levels:
        return 0
    mem, tmp = _scratch_layer()
    gdal.ContourGenerate(src.GetRasterBand(1), 0.0, 0.0, levels, 0, 0.0, tmp, 0, 1)
    defn = out_lyr.GetLayerDefn()
    n = 0
    ds.StartTransaction()
    tmp.ResetReading()
    for f in tmp:
        geom = f.GetGeometryRef()
        if geom is None:
            continue
        elev = f.GetFieldAsDouble(1)
        out = ogr.Feature(defn)
        out.SetGeometry(geom)
        out.SetField("id", n)
        out.SetField("elev_m", elev)
        k = int(round(elev / CONTOUR_INTERVAL_M))
        out.SetField("major", 1 if k % INDEX_EVERY == 0 else 0)
        out.SetField("massif", names[:254])
        out_lyr.CreateFeature(out)
        n += 1
    ds.CommitTransaction()
    mem = None
    return n


def _load_ground():
    path = os.path.join(link_modifiers.resolve_export_dir(), f"{PLANET_NAME}_heightmap.tif")
    if not os.path.exists(path):
        print(f"  ! {path} not found — contours relative to the ground instead.")
        return None
    ds = gdal.Open(path)
    arr = ds.GetRasterBand(1).ReadAsArray().astype(np.float64)
    gt = ds.GetGeoTransform()
    ds = None
    print(f"  Ground: {os.path.basename(path)} {arr.shape[1]}×{arr.shape[0]}")
    return lambda lon, lat: mp.bilinear_equirect(arr, gt, lon, lat)


# ============================================================
# Styling
# ============================================================
def _style_contours(layer):
    minor = QgsLineSymbol.createSimple({"color": "#8b5a2b", "width": "0.18"})
    major = QgsLineSymbol.createSimple({"color": "#5a3414", "width": "0.5"})
    step = CONTOUR_INTERVAL_M
    layer.setRenderer(QgsCategorizedSymbolRenderer("major", [
        QgsRendererCategory(0, minor, f"every {step:g} m"),
        QgsRendererCategory(1, major, f"every {step * INDEX_EVERY:g} m"),
    ]))
    try:
        pal = QgsPalLayerSettings()
        pal.isExpression = True
        sign = "" if ADD_GROUND_ELEVATION else "'+' || "
        pal.fieldName = f"CASE WHEN \"major\" = 1 THEN {sign}format_number(\"elev_m\", 0) || ' m' END"
        try:
            pal.placement = Qgis.LabelPlacement.Line
        except AttributeError:  # QGIS < 3.26
            pal.placement = QgsPalLayerSettings.Line
        fmt = QgsTextFormat()
        fmt.setSize(8)
        fmt.setColor(QColor("#5a3414"))
        buf = QgsTextBufferSettings()
        buf.setEnabled(True)
        buf.setSize(0.8)
        buf.setColor(QColor(255, 255, 255, 200))
        fmt.setBuffer(buf)
        pal.setFormat(fmt)
        layer.setLabeling(QgsVectorLayerSimpleLabeling(pal))
        layer.setLabelsEnabled(True)
    except Exception as exc:  # labels are a comfort: never lose the contours for them
        print(f"  ! labels not set: {exc}")


def _smooth_when_zoomed(layer):
    """Bilinear resampling when zoomed in: with the default nearest neighbour the
    hillshade sees a step at every cell edge and draws the grid as dark squares."""
    try:
        bilinear = QgsRasterDataProvider.ResamplingMethod.Bilinear
        layer.dataProvider().setZoomedInResamplingMethod(bilinear)
        layer.dataProvider().setZoomedOutResamplingMethod(bilinear)
    except AttributeError:  # QGIS < 3.16: resample the rendered image instead
        layer.resampleFilter().setZoomedInResampler(QgsBilinearRasterResampler())


def _style_relief(layer):
    _smooth_when_zoomed(layer)
    try:
        r = QgsHillshadeRenderer(layer.dataProvider(), 1, 315.0, 45.0)
        # The raster's cells are in degrees and its values in metres.
        r.setZFactor(180.0 / (math.pi * PLANET_RADIUS))
        r.setMultiDirectional(True)
        layer.setRenderer(r)
        layer.renderer().setOpacity(0.55)
    except Exception as exc:
        print(f"  ! hillshade not set: {exc}")


# ============================================================
# Run
# ============================================================
def prepare(**options):
    """Main thread: read the features, clear the previous preview. Returns the computation
    (any thread), which returns the step that adds the layers (main thread)."""
    _configure(options)
    print("=" * 64)
    print(f"  Mountain preview — planet '{PLANET_NAME}' (R = {PLANET_RADIUS} m)")
    print("=" * 64)
    t0 = time.time()
    feats = collect_features()
    if not feats:
        print("  ✗ No mountain_range / ridge feature"
              + (" selected." if ONLY_SELECTED else " (re-run setup_planet_project.py to create the layers)."))
        return None
    pad_m = max(4.0 * SAMPLE_SPACING_M, 200.0)
    groups = mp.cluster_boxes(feats, PLANET_RADIUS, pad_m)
    view = _canvas_box() if ONLY_CANVAS_EXTENT else None
    if view is not None:
        groups = [(b, m) for b, m in ((mp.intersect_boxes(box, view), m) for box, m in groups) if b]
        print(f"  Canvas extent only: lon {view[0]:.3f}…{view[1]:.3f}, lat {view[2]:.3f}…{view[3]:.3f}")
        if not groups:
            print("  ✗ No mountain in the canvas extent — pan to a massif, or untick \"canvas extent only\".")
            return None
    ground = _load_ground() if ADD_GROUND_ELEVATION else None

    out_dir = _output_dir()
    _drop_previous(out_dir)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    gpkg = os.path.join(out_dir, f"{PLANET_NAME}_mountain_preview_{stamp}.gpkg")

    def work():
        rasters, n_lines = _compute(feats, groups, view, ground, out_dir, stamp, gpkg)
        return lambda: _add_layers(gpkg, rasters, n_lines, t0)
    return work


def _compute(feats, groups, view, ground, out_dir, stamp, gpkg):
    """The relief grids, their contours into [gpkg] and the hillshade GeoTIFFs; no QGIS layer."""
    ds = ogr.GetDriverByName("GPKG").CreateDataSource(gpkg)
    lyr = ds.CreateLayer("contours", _wgs84(), ogr.wkbLineString)
    lyr.CreateField(ogr.FieldDefn("id", ogr.OFTInteger))
    lyr.CreateField(ogr.FieldDefn("elev_m", ogr.OFTReal))
    lyr.CreateField(ogr.FieldDefn("major", ogr.OFTInteger))
    massif_def = ogr.FieldDefn("massif", ogr.OFTString)
    massif_def.SetWidth(254)
    lyr.CreateField(massif_def)

    print(f"  {len(feats)} feature(s) in {len(groups)} group(s), pitch {SAMPLE_SPACING_M:g} m")
    rasters = []
    n_lines = 0
    for gi, (box, members) in enumerate(groups, 1):
        t = time.time()
        lons, lats, spacing = mp.grid_for_box(box, PLANET_RADIUS, SAMPLE_SPACING_M, MAX_SAMPLES)
        grid = mp.evaluate_grid(lons, lats, PLANET_RADIUS, members, spacing, ground=ground)
        names = ", ".join(sorted({f["name"] for f in members if f["name"]})) or f"group {gi}"
        src = _mem_raster(grid, lons, lats)
        added = _add_contours(src, _levels(float(grid.min()), float(grid.max())), ds, lyr, names)
        n_lines += added
        if ADD_RELIEF_RASTER:
            tif = os.path.join(out_dir, f"{PLANET_NAME}_mountain_relief_{stamp}_{gi}.tif")
            gdal.GetDriverByName("GTiff").CreateCopy(tif, src, options=["COMPRESS=DEFLATE"])
            rasters.append((tif, names))
        src = None
        warn = ""
        if spacing > SAMPLE_SPACING_M:
            warn = (f"\n      ! pitch raised to {spacing:.0f} m (max samples): the contours lose the details"
                    f" finer than {2 * spacing:.0f} m — zoom in"
                    + (" (canvas extent only is off)" if view is None else "") + " or raise the max samples.")
        print(f"  [{gi}/{len(groups)}] {names[:40]:<40} {len(lons)}×{len(lats)} "
              f"{grid.min():7.0f}…{grid.max():5.0f} m  {added:4d} lines  {time.time() - t:5.1f} s{warn}")
    ds = None
    return rasters, n_lines


def _add_layers(gpkg, rasters, n_lines, t0):
    """Main thread: the preview group at the top of the layer tree."""
    root = QgsProject.instance().layerTreeRoot()
    group = root.insertGroup(0, GROUP_NAME)
    contours = QgsVectorLayer(f"{gpkg}|layername=contours", "Mountain contours", "ogr")
    contours.setCustomProperty(_PREVIEW_TAG, "contours")
    _style_contours(contours)
    QgsProject.instance().addMapLayer(contours, False)
    group.addLayer(contours)
    for i, (tif, names) in enumerate(rasters, 1):
        rl = QgsRasterLayer(tif, f"Mountain relief {i} — {names[:40]}")
        rl.setCustomProperty(_PREVIEW_TAG, "relief")
        _style_relief(rl)
        QgsProject.instance().addMapLayer(rl, False)
        group.addLayer(rl)
        group.findLayer(rl.id()).setExpanded(False)

    what = "absolute altitude" if ADD_GROUND_ELEVATION else "height above the ground"
    print("-" * 64)
    print(f"  ✓ {n_lines} contour line(s), {what}, every {CONTOUR_INTERVAL_M:g} m — {time.time() - t0:.1f} s")
    print(f"    {gpkg}")
    print("=" * 64)


def run(**options):
    """The whole preview, on the calling (main) thread."""
    work = prepare(**options)
    if work is not None:
        finish = work()
        finish()


if __name__ == "__main__":
    run()
