"""The ground of the area on screen, to draw roads over: altitude (hillshade + contours), slope
classes against the road's max slope, corundum chasms.

Two sources, one grid (export/planet/terrain_grid.py):

    quick  — QGIS alone, nothing to export: the contours through the spherical TIN the
             elevation export uses (export/planet/spherical_tin.py) + the mountain ranges and
             ridges as drawn (export/planet/mountain_preview.py, Godot's values to 1e-9 m).
             Not in it: volcanoes and rocky terrain, and the game reads the elevation through
             its 198 m pack texels where this reads the TIN itself — close, not exact.
    exact  — Godot without a window (tools/planettech/terrain_dem.tscn): the very function the
             road and railway profiles read (PlanetData.grade_height_sampler). The modifiers come
             from the local terrainmodifier.pack the last export linked (a massif just exported
             shows without publishing), the elevation from the tile service.

Run from QGIS: DyingStar ▸ Routes ▸ Terrain de la zone… From the Python console:
    import zone_terrain; zone_terrain.run(source="quick", pitch_m=25)
"""
import configparser
import datetime
import glob
import math
import os
import subprocess
import sys
import tempfile
import time

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import numpy as np                                        # noqa: E402

import ds_project                                         # noqa: E402
import link_modifiers                                     # noqa: E402
from export.planet import terrain_grid as tg              # noqa: E402

GROUP_NAME = "DyingStar — terrain"
#: Custom property on the layers this module adds: "dem", "slope", "cracks", "contours".
TAG = "ds_terrain"
#: The quick source's ceiling (numpy temporaries) and the exact one's (terrain_dem.gd's own).
MAX_SAMPLES = {"quick": 8_000_000, "exact": 32_000_000}
#: Slope classes (zone_terrain.style_slope): the road follows the ground / goes across / no.
COLORS = {"follow": "#3a9d23", "across": "#f0a020", "structure": "#d7301f", "cracks": "#7b2cbf"}

#: Set by the plugin's runner: callable(fraction); raises to cancel.
PROGRESS = None


def _progress(f):
    if PROGRESS is not None:
        PROGRESS(f)


# ── Main thread: what to compute ───────────────────────────────────────────────
def prepare(source="quick", pitch_m=25.0, contour_m=25.0, cracks=True, local_modifiers=True,
            tile_channel="", only_canvas=True, max_slope_deg=8.0, steep_deg=30.0):
    """Main thread: read the planet, the area, and (quick) the contours and the mountain features.
    Returns the computation (any thread), which returns the step adding the layers."""
    if source not in MAX_SAMPLES:
        raise ValueError(f"source {source!r}: quick or exact")
    planet = ds_project.planet()
    box = _canvas_box() if only_canvas else None
    if box is None:
        raise RuntimeError("no map canvas extent: zoom on the area (the whole planet at a road's "
                           "pitch is billions of samples)")
    grid, pitch = tg.Grid.for_box(box, planet.radius_m, pitch_m, MAX_SAMPLES[source])
    print("=" * 64)
    print(f"  Zone terrain ({source}) — planet '{planet.name}'")
    print(f"  lon {box[0]:.4f}…{box[1]:.4f}, lat {box[2]:.4f}…{box[3]:.4f} — "
          f"{grid.nx} × {grid.ny} nodes, pitch {pitch:.1f} m"
          + (f" (raised from {pitch_m:g} m: zoom in for more detail)" if pitch > pitch_m else ""))
    out_dir = _output_dir()
    _drop_previous(out_dir, planet.name)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    base = os.path.join(out_dir, f"{planet.name}_{source}_{stamp}")
    style = {"max_slope_deg": max_slope_deg, "steep_deg": steep_deg, "contour_m": contour_m}
    if source == "quick":
        inputs = _quick_inputs(planet, box, pitch)
        compute = lambda: _quick(planet, grid, pitch, inputs)  # noqa: E731
    else:
        cmd = _godot_command(planet, grid, base, cracks, local_modifiers, tile_channel)
        compute = lambda: _exact(cmd, base)  # noqa: E731

    def work():
        t0 = time.time()
        z, cr, radius, note = compute()
        files = _write(base, grid, z, cr, radius, contour_m)
        print(f"  {note}")
        print(f"  altitude {float(np.nanmin(z)):.0f} … {float(np.nanmax(z)):.0f} m — "
              f"{time.time() - t0:.1f} s")
        return lambda: _add_layers(files, source, pitch, radius, style)
    return work


def run(**options):
    """The whole job on the calling (main) thread."""
    work = prepare(**options)
    finish = work()
    finish()


def _canvas_box():
    try:
        from qgis.utils import iface
        canvas = iface.mapCanvas()
    except Exception:  # noqa: BLE001 — no GUI
        return None
    from qgis.core import QgsCoordinateReferenceSystem, QgsCoordinateTransform, QgsProject
    ext = canvas.extent()
    crs = canvas.mapSettings().destinationCrs()
    wgs = QgsCoordinateReferenceSystem("EPSG:4326")
    if crs != wgs:
        ext = QgsCoordinateTransform(crs, wgs, QgsProject.instance()).transformBoundingBox(ext)
    lo0, lo1 = max(ext.xMinimum(), -180.0), min(ext.xMaximum(), 180.0)
    la0, la1 = max(ext.yMinimum(), -89.9), min(ext.yMaximum(), 89.9)
    if lo1 <= lo0 or la1 <= la0:
        return None
    return (lo0, lo1, la0, la1)


def _output_dir():
    from qgis.core import QgsProject
    home = QgsProject.instance().absolutePath()
    d = os.path.join(home, "zone_terrain") if home else \
        os.path.join(tempfile.gettempdir(), "ds_zone_terrain")
    os.makedirs(d, exist_ok=True)
    return d


def _drop_previous(out_dir, planet_name):
    """The previous terrain's layers, then its files (the layers first: Windows keeps an open
    file). Files still locked are left; every run writes new, stamped names."""
    from qgis.core import QgsProject
    project = QgsProject.instance()
    for layer in list(project.mapLayers().values()):
        if layer.customProperty(TAG, ""):
            project.removeMapLayer(layer.id())
    root = project.layerTreeRoot()
    group = root.findGroup(GROUP_NAME)
    if group is not None:
        root.removeChildNode(group)
    for path in glob.glob(os.path.join(out_dir, f"{planet_name}_*")):
        try:
            os.remove(path)
        except OSError:
            pass


# ── Quick source ───────────────────────────────────────────────────────────────
def _quick_inputs(planet, box, pitch):
    """Main thread: the contour vertices (as the elevation export reads them) and the mountain
    features near the box."""
    from qgis.core import QgsProject
    import export_elevation
    from export.planet.heightmap import extract_contour_points
    from export.planet import mountain_preview as mp
    import preview_mountain_contours as pmc

    def find_layers_by_keyword(keyword):
        kw = keyword.lower()
        return [lyr for lyr in QgsProject.instance().mapLayers().values()
                if kw in lyr.name().lower()]

    pts = extract_contour_points(export_elevation.HEIGHTMAP_SIZE, find_layers_by_keyword,
                                 lambda *a: None)
    print(f"  contours : {0 if pts is None else len(pts)} vertices")
    pmc._configure({"only_selected": False})
    feats = pmc.collect_features()
    pad = max(4.0 * pitch, 200.0)
    near = []
    for fbox, members in mp.cluster_boxes(feats, planet.radius_m, pad):
        if mp.intersect_boxes(fbox, box):
            near.extend(members)
    print(f"  mountains: {len(near)} range(s) / ridge(s) over the area (of {len(feats)})")
    return {"pts": pts, "features": near}


def _quick(planet, grid, pitch, inputs):
    from export.planet import mountain_preview as mp
    pts = inputs["pts"]
    glon, glat = np.meshgrid(grid.lons, grid.lats)
    if pts is not None and len(pts) >= 4:
        from export.planet.spherical_tin import SphericalTIN
        print("  TIN of the contours…")
        tin = SphericalTIN(pts[:, 0], pts[:, 1], pts[:, 2])
        _progress(0.3)
        base = tin.sample_lonlat(glon, glat)
    else:
        print("  ! no contour: the ground is flat at 0 m")
        base = np.zeros(grid.shape)
    _progress(0.5)
    z = base
    if inputs["features"]:
        z = base + mp.evaluate_grid(grid.lons, grid.lats, planet.radius_m, inputs["features"],
                                    pitch, progress=lambda d, n: _progress(0.5 + 0.4 * d / n))
    note = ("quick source: contour TIN + mountain ranges and ridges as drawn — no volcanoes, no "
            "rocky terrain; validate with the exact source before exporting a road")
    return z.astype(np.float32), None, planet.radius_m, note


# ── Exact source ───────────────────────────────────────────────────────────────
def godot_binary():
    """$GODOT_BIN (plugin setting "Binaire Godot"), else export_config.ini [godot] path."""
    path = os.environ.get("GODOT_BIN", "").strip()
    if not path:
        ini = os.path.join(_THIS_DIR, "export_config.ini")
        if os.path.exists(ini):
            cp = configparser.ConfigParser()
            cp.read(ini)
            path = cp.get("godot", "path", fallback="").strip()
    if not path or not os.path.exists(path):
        raise RuntimeError("Godot binary not found (" + (path or "not set") + "): set "
                           "« Binaire Godot » in DyingStar ▸ Paramètres — the project's engine")
    return path


def _godot_command(planet, grid, base, cracks, local_modifiers, tile_channel):
    repo = link_modifiers.repo_root()
    if repo is None:
        raise RuntimeError("DyingStar checkout not found: set it in the plugin settings")
    if not os.path.exists(os.path.join(repo, "tools", "planettech", "terrain_dem.tscn")):
        raise RuntimeError(f"{repo} has no tools/planettech/terrain_dem.tscn: that checkout is on "
                           f"a branch without the terrain tool — set « Dépôt DyingStar » to one "
                           f"that has it")
    cmd = [godot_binary(), "--headless", "--path", repo,
           "res://tools/planettech/terrain_dem.tscn", "--",
           f"--planet={planet.name}", grid.godot_arg(), f"--out={base}"]
    if cracks:
        cmd.append("--cracks")
    if tile_channel:
        cmd.append(f"--tile-channel={tile_channel}")
    if local_modifiers:
        pack = os.path.join(link_modifiers.chunks_dir_for(planet.name,
                                                          link_modifiers.resolve_export_dir()),
                            "terrainmodifier.pack")
        if os.path.exists(pack):
            cmd.append(f"--local-modifiers={pack}")
            print(f"  modifiers: local {pack}")
        else:
            print(f"  modifiers: published (no local {pack})")
    return cmd


def _exact(cmd, base):
    print("  $ " + " ".join(cmd))
    log = base + ".log"
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    seen = 0
    try:
        while proc.poll() is None:
            time.sleep(0.25)
            seen = _relay_log(log, seen)
        seen = _relay_log(log, seen)
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    err = proc.stderr.read() if proc.stderr else ""
    if proc.returncode != 0 or not os.path.exists(base + ".json"):
        tail = "\n".join(line for line in err.splitlines()[-15:] if line.strip())
        raise RuntimeError(f"terrain_dem.gd failed (exit {proc.returncode}); see {log}\n{tail}")
    z, meta, cracks = tg.read_godot(base)
    if not meta.get("complete", True):
        print("  ! some elevation tiles were missing: those places read the coarse global map")
    if meta.get("verify_max_abs_diff_m", 0.0) != 0.0:
        print(f"  ! self-check off by {meta['verify_max_abs_diff_m']} m")
    note = (f"exact source: {meta.get('sampler')}, modifiers {meta.get('modifiers')}, "
            f"elevation channel {meta.get('tile_channel')}")
    return z, cracks, float(meta["radius_m"]), note


def _relay_log(path, seen):
    """Print terrain_dem.gd's new log lines; its progress lines become the task's progress."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return seen
    for line in lines[seen:]:
        if line.startswith("[TerrainDem] progress "):
            try:
                _progress(0.05 + 0.9 * float(line.split()[-1]))
            except ValueError:
                pass
        elif "first missing tile chain" not in line:
            print("  " + line)
    return len(lines)


# ── Files ──────────────────────────────────────────────────────────────────────
def _write(base, grid, z, cracks, radius, contour_m):
    """GeoTIFFs (altitude, slope, chasm depth) and the contours' GeoPackage."""
    from osgeo import gdal, ogr, osr
    gdal.UseExceptions()
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(4326)
    srs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)

    def tif(path, arr, dtype=gdal.GDT_Float32, nodata=None):
        ds = gdal.GetDriverByName("GTiff").Create(path, grid.nx, grid.ny, 1, dtype,
                                                  options=["COMPRESS=DEFLATE", "TILED=YES"])
        ds.SetGeoTransform(grid.geotransform())
        ds.SetProjection(srs.ExportToWkt())
        band = ds.GetRasterBand(1)
        if nodata is not None:
            band.SetNoDataValue(nodata)
        band.WriteArray(arr)
        band.FlushCache()
        return ds

    files = {"dem": base + "_dem.tif", "slope": base + "_slope.tif"}
    dem = tif(files["dem"], z.astype(np.float32))
    slope = tg.slope_deg(z, grid, radius)
    tif(files["slope"], slope)
    if cracks is not None and float(np.nanmax(cracks)) > 0.0:
        files["cracks"] = base + "_cracks.tif"
        tif(files["cracks"], cracks.astype(np.float32), nodata=0.0)
    if contour_m and contour_m > 0:
        files["contours"] = base + "_contours.gpkg"
        out = ogr.GetDriverByName("GPKG").CreateDataSource(files["contours"])
        lyr = out.CreateLayer("contours", srs, ogr.wkbLineString)
        lyr.CreateField(ogr.FieldDefn("id", ogr.OFTInteger))
        lyr.CreateField(ogr.FieldDefn("elev_m", ogr.OFTReal))
        gdal.ContourGenerate(dem.GetRasterBand(1), float(contour_m), 0.0, [], 0, 0.0, lyr, 0, 1)
        out = None
    dem = None
    print(f"  slope    : {float(np.nanmax(slope)):.1f}° max — "
          f"{100.0 * float(np.mean(slope > 30.0)):.0f} % steeper than 30°")
    return files


# ── Main thread: the layers ────────────────────────────────────────────────────
def _add_layers(files, source, pitch, radius, style):
    from qgis.core import QgsProject, QgsRasterLayer, QgsVectorLayer
    project = QgsProject.instance()
    root = project.layerTreeRoot()
    group = root.insertGroup(0, GROUP_NAME)
    label = "exact" if source == "exact" else "rapide"

    def add(layer, tag, expanded=False):
        layer.setCustomProperty(TAG, tag)
        project.addMapLayer(layer, False)
        node = group.addLayer(layer)
        node.setExpanded(expanded)
        return layer

    if "contours" in files:
        c = QgsVectorLayer(f"{files['contours']}|layername=contours",
                           f"Courbes {style['contour_m']:g} m ({label})", "ogr")
        _style_contours(c, style["contour_m"])
        add(c, "contours")
    if "cracks" in files:
        add(_style_cracks(QgsRasterLayer(files["cracks"], "Crevasses (profondeur)")), "cracks")
    sl = QgsRasterLayer(files["slope"], "Pente — praticabilité")
    style_slope(sl, style["max_slope_deg"], style["steep_deg"])
    add(sl, "slope", True)
    dem = QgsRasterLayer(files["dem"], f"Terrain {label} — pas {pitch:.0f} m")
    _style_dem(dem, radius)
    add(dem, "dem")
    print("-" * 64)
    print(f"  ✓ « {GROUP_NAME} »: terrain {label}, slope classes for {style['max_slope_deg']:g}° "
          f"(change it in the Routes toolbar)")
    print("=" * 64)


def _style_dem(layer, radius):
    from qgis.core import QgsBilinearRasterResampler, QgsHillshadeRenderer
    r = QgsHillshadeRenderer(layer.dataProvider(), 1, 315.0, 45.0)
    # Cells in degrees, values in metres.
    r.setZFactor(180.0 / (math.pi * radius))
    r.setMultiDirectional(True)
    layer.setRenderer(r)
    layer.renderer().setOpacity(0.6)
    layer.resampleFilter().setZoomedInResampler(QgsBilinearRasterResampler())


def style_slope(layer, max_slope_deg, steep_deg):
    """Colour the slope raster in three classes for a road of [max_slope_deg] — redone without
    recomputing anything when the max slope changes (Routes toolbar)."""
    from qgis.core import (QgsColorRampShader, QgsRasterShader,
                           QgsSingleBandPseudoColorRenderer)
    from qgis.PyQt.QtGui import QColor
    steep = max(float(steep_deg), float(max_slope_deg))
    ramp = QgsColorRampShader()
    ramp.setColorRampType(QgsColorRampShader.Type.Discrete)
    ramp.setColorRampItemList([
        QgsColorRampShader.ColorRampItem(float(max_slope_deg), QColor(COLORS["follow"]),
                                         f"≤ {max_slope_deg:g}° : la route suit le terrain"),
        QgsColorRampShader.ColorRampItem(steep, QColor(COLORS["across"]),
                                         f"≤ {steep:g}° : en biais, lacets, tranchée/remblai"),
        QgsColorRampShader.ColorRampItem(90.0, QColor(COLORS["structure"]),
                                         f"> {steep:g}° : tunnel ou viaduc"),
    ])
    shader = QgsRasterShader()
    shader.setRasterShaderFunction(ramp)
    r = QgsSingleBandPseudoColorRenderer(layer.dataProvider(), 1, shader)
    r.setClassificationMin(0.0)
    r.setClassificationMax(90.0)
    layer.setRenderer(r)
    layer.renderer().setOpacity(0.45)
    layer.setCustomProperty("ds_max_slope_deg", float(max_slope_deg))
    layer.setCustomProperty("ds_steep_deg", steep)
    layer.triggerRepaint()


def restyle_all(max_slope_deg, steep_deg):
    """Every slope layer of the project, for a new max slope."""
    from qgis.core import QgsProject
    n = 0
    for layer in QgsProject.instance().mapLayers().values():
        if layer.customProperty(TAG, "") == "slope":
            style_slope(layer, max_slope_deg, steep_deg)
            n += 1
    return n


def _style_cracks(layer):
    from qgis.core import (QgsColorRampShader, QgsRasterShader,
                           QgsSingleBandPseudoColorRenderer)
    from qgis.PyQt.QtGui import QColor
    ramp = QgsColorRampShader()
    ramp.setColorRampType(QgsColorRampShader.Type.Discrete)
    ramp.setColorRampItemList([
        QgsColorRampShader.ColorRampItem(0.5, QColor(0, 0, 0, 0), "sol"),
        QgsColorRampShader.ColorRampItem(1e9, QColor(COLORS["cracks"]), "crevasse : pont"),
    ])
    shader = QgsRasterShader()
    shader.setRasterShaderFunction(ramp)
    layer.setRenderer(QgsSingleBandPseudoColorRenderer(layer.dataProvider(), 1, shader))
    layer.renderer().setOpacity(0.7)
    return layer


def _style_contours(layer, step_m):
    from qgis.core import QgsLineSymbol, QgsRuleBasedRenderer
    major = 5 * step_m
    root = QgsRuleBasedRenderer.Rule(None)
    for expr, width, color in ((f'abs("elev_m" / {major} - round("elev_m" / {major})) < 1e-6',
                                "0.35", "#5a3d1e"),
                               ("ELSE", "0.15", "#8c6a46")):
        rule = QgsRuleBasedRenderer.Rule(QgsLineSymbol.createSimple(
            {"color": color, "width": width}), 0, 0, "" if expr == "ELSE" else expr)
        if expr == "ELSE":
            rule.setIsElse(True)
        root.appendChild(rule)
    layer.setRenderer(QgsRuleBasedRenderer(root))
