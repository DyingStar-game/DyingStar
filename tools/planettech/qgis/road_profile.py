"""The longitudinal profile of a road feature over the zone terrain, for the profile panel.

The terrain is the "DyingStar — terrain" altitude layer (zone_terrain.py), read bilinearly; the
along-distance is the road exporter's (modifier_geom.cumulative_lengths, the project's radius);
the rule is the game's (export/planet/grade_profile.py, pinned to GradeProfile). The grade:
`railway` → RailwaySettings.MAX_GRADE; `highway` / `road` with `max_slope_degrees` → that; any
other line → the Routes toolbar's max slope, as a "what if" the panel says it is.
"""
import math
import os
import sys

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import numpy as np                                        # noqa: E402

import ds_project                                         # noqa: E402
from export.planet import grade_profile as gp             # noqa: E402
from export.planet import modifier_geom                   # noqa: E402
from export.planet import terrain_grid as tg              # noqa: E402

#: DEM rasters read, by path: (heights, grid). A path is stamped, so never stale.
_DEMS = {}


class NoTerrain(RuntimeError):
    """No zone terrain covers the road."""


def dem_layers():
    from qgis.core import QgsProject
    return [lyr for lyr in QgsProject.instance().mapLayers().values()
            if lyr.customProperty("ds_terrain", "") == "dem"]


def _read_dem(path):
    if path not in _DEMS:
        from osgeo import gdal
        gdal.UseExceptions()
        ds = gdal.Open(path)
        z = ds.GetRasterBand(1).ReadAsArray().astype(np.float64)
        grid = tg.Grid.from_geotransform(ds.GetGeoTransform(), ds.RasterXSize, ds.RasterYSize)
        ds = None
        if len(_DEMS) > 4:
            _DEMS.clear()
        _DEMS[path] = (z, grid)
    return _DEMS[path]


def road_line(layer, feature):
    """[(lon, lat), …] of the feature (its longest part), in EPSG:4326."""
    from qgis.core import (QgsCoordinateReferenceSystem, QgsCoordinateTransform, QgsProject)
    geom = feature.geometry()
    if geom is None or geom.isEmpty():
        return []
    wgs = QgsCoordinateReferenceSystem("EPSG:4326")
    if layer.crs() != wgs:
        geom = type(geom)(geom)
        geom.transform(QgsCoordinateTransform(layer.crs(), wgs, QgsProject.instance()))
    parts = geom.asMultiPolyline() if geom.isMultipart() else [geom.asPolyline()]
    parts = [p for p in parts if len(p) >= 2]
    if not parts:
        return []
    best = max(parts, key=len)
    return [(float(p.x()), float(p.y())) for p in best]


def grade_of(layer, feature, fallback_deg):
    """(max grade rise/run, label, is it the toolbar's what-if, road type)."""
    road_type = str(layer.customProperty("road_type", "") or "")
    if not road_type and feature.fields().indexOf("road_type") >= 0:
        road_type = str(feature["road_type"] or "")
    slope = None
    if feature.fields().indexOf("max_slope_degrees") >= 0:
        v = feature["max_slope_degrees"]
        if v is not None and str(v) != "NULL":
            slope = float(v)
    g = gp.max_grade_of(road_type, slope)
    if g is not None:
        label = (f"rail {100 * g:.0f} %" if road_type == "railway"
                 else f"{road_type} {slope:g}° ({100 * g:.1f} %)")
        return g, label, False, road_type
    g = math.tan(math.radians(fallback_deg))
    what = road_type or layer.name()
    return (g, f"{what} sans pente max — hypothèse {fallback_deg:g}° de la barre d'outils", True,
            road_type)


def profile_of(layer, feature, fallback_deg):
    """The profile of a road feature: {profile, summary, line, cum, grade_label, what_if,
    terrain_name}. Raises NoTerrain when no zone terrain covers the road."""
    planet = ds_project.planet()
    line = road_line(layer, feature)
    if len(line) < 2:
        raise ValueError("the feature has no line")
    mpd = planet.radius_m * math.pi / 180.0
    cum = modifier_geom.cumulative_lengths(line, mpd)
    a0, a1 = cum[0], cum[-1]
    stations = gp.station_alongs(a0, a1)
    lonlat = np.array([gp.lonlat_at(line, cum, a) for a in stations])
    best = None
    for lyr in dem_layers():
        z, grid = _read_dem(lyr.source())
        h = tg.bilinear(z, grid, lonlat[:, 0], lonlat[:, 1])
        covered = float(np.mean(np.isfinite(h)))
        if best is None or covered > best[0]:
            best = (covered, lyr, z, grid, h)
    if best is None:
        raise NoTerrain("no zone terrain: DyingStar ▸ Routes ▸ Terrain de la zone first")
    covered, lyr, z, grid, st = best
    if covered < 1.0:
        raise NoTerrain(f"the zone terrain covers {100 * covered:.0f} % of the road: compute it "
                        f"over the whole road (zoom out, or raise the pitch)")

    def terrain(along):
        lon, lat = gp.lonlat_at(line, cum, along)
        return float(tg.bilinear(z, grid, np.array([lon]), np.array([lat]))[0])

    grade, label, what_if, road_type = grade_of(layer, feature, fallback_deg)
    prof = gp.compute(a0, a1, terrain, grade, gp.climbs_at_max_grade_of(road_type),
                      stations_terrain=[float(v) for v in st])
    if prof is None:
        raise ValueError("the road is too short to profile (< 5 m)")
    return {"profile": prof, "summary": gp.summary(prof), "line": line, "cum": cum,
            "grade_label": label, "what_if": what_if, "terrain_name": lyr.name()}
