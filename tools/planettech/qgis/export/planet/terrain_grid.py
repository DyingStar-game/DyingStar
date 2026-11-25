"""The terrain of an area as a lon/lat grid, for the road tools — numpy only, no QGIS.

One grid convention for both sources of zone_terrain.py (the quick Python one and Godot's
tools/planettech/terrain_dem.gd): nodes at lon = lon0 + i·dlon, lat = lat_top − j·dlat, row 0 to
the north, the east-west pitch taken at the area's mid latitude (export/planet/mountain_preview.py
grid_for_box). As a raster, each node is a pixel CENTRE.

The slope is computed in true metres on the sphere (an east-west step is R·cos φ·dλ): the slope
algorithms of QGIS / GDAL take one scale for the whole raster, wrong on a lon/lat grid away from
the equator.
"""
import json
import math
from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Grid:
    lon0: float
    dlon: float
    nx: int
    lat_top: float
    dlat: float
    ny: int

    @staticmethod
    def for_box(box, radius_m, pitch_m, max_samples):
        """The grid over box = (lon0, lon1, lat0, lat1) at ~pitch_m, coarsened (×1.25 steps) to at
        most max_samples nodes. Returns (grid, pitch actually used, m)."""
        m_per_deg = radius_m * math.pi / 180.0
        lo0, lo1, la0, la1 = box
        clat = max(math.cos(math.radians((la0 + la1) * 0.5)), 0.05)
        width_m = (lo1 - lo0) * m_per_deg * clat
        height_m = (la1 - la0) * m_per_deg
        pitch = float(pitch_m)
        while (width_m / pitch + 1.0) * (height_m / pitch + 1.0) > max_samples:
            pitch *= 1.25
        dlat = pitch / m_per_deg
        dlon = dlat / clat
        nx = int(math.ceil((lo1 - lo0) / dlon)) + 1
        ny = int(math.ceil((la1 - la0) / dlat)) + 1
        return Grid(float(lo0), dlon, nx, float(la1), dlat, ny), pitch

    @staticmethod
    def from_meta(meta):
        return Grid(float(meta["lon0"]), float(meta["dlon"]), int(meta["nx"]),
                    float(meta["lat_top"]), float(meta["dlat"]), int(meta["ny"]))

    @property
    def lons(self):
        return self.lon0 + self.dlon * np.arange(self.nx)

    @property
    def lats(self):
        return self.lat_top - self.dlat * np.arange(self.ny)

    @property
    def shape(self):
        return (self.ny, self.nx)

    @staticmethod
    def from_geotransform(gt, nx, ny):
        """The grid of a raster written with geotransform() (pixel centres = nodes)."""
        x0, px, _, y0, _, py = gt
        return Grid(x0 + 0.5 * px, px, int(nx), y0 + 0.5 * py, -py, int(ny))

    def geotransform(self):
        """GDAL geotransform whose pixel centres are the nodes."""
        return (self.lon0 - self.dlon * 0.5, self.dlon, 0.0,
                self.lat_top + self.dlat * 0.5, 0.0, -self.dlat)

    def godot_arg(self):
        """The --grid argument of terrain_dem.gd (repr: no digit lost on the way)."""
        return "--grid=%r,%r,%d,%r,%r,%d" % (self.lon0, self.dlon, self.nx,
                                            self.lat_top, self.dlat, self.ny)


def slope_deg(z, grid, radius_m):
    """Slope (degrees) of the heights z[ny, nx] on [grid], central differences in metres."""
    z = np.asarray(z, dtype=np.float64)
    if z.shape != grid.shape:
        raise ValueError(f"grid {grid.shape} but heights {z.shape}")
    dy_m = radius_m * math.radians(grid.dlat)
    cos_lat = np.maximum(np.cos(np.radians(grid.lats)), 1e-6)
    dx_m = radius_m * math.radians(grid.dlon) * cos_lat
    # Rows go southwards: d/dnorth = -d/drow.
    dz_north = -np.gradient(z, axis=0) / dy_m
    dz_east = np.gradient(z, axis=1) / dx_m[:, None]
    return np.degrees(np.arctan(np.hypot(dz_east, dz_north))).astype(np.float32)


def bilinear(z, grid, lon, lat):
    """Heights at (lon, lat) arrays, bilinear between the nodes; NaN outside the grid."""
    lon = np.asarray(lon, dtype=np.float64)
    lat = np.asarray(lat, dtype=np.float64)
    fx = (lon - grid.lon0) / grid.dlon
    fy = (grid.lat_top - lat) / grid.dlat
    eps = 1e-6   # a node on the edge must not fall outside by a rounding
    inside = (fx >= -eps) & (fx <= grid.nx - 1 + eps) & (fy >= -eps) & (fy <= grid.ny - 1 + eps)
    ix = np.clip(np.floor(fx).astype(np.int64), 0, grid.nx - 2)
    iy = np.clip(np.floor(fy).astype(np.int64), 0, grid.ny - 2)
    tx = np.clip(fx - ix, 0.0, 1.0)
    ty = np.clip(fy - iy, 0.0, 1.0)
    a = z[iy, ix] * (1.0 - tx) + z[iy, ix + 1] * tx
    b = z[iy + 1, ix] * (1.0 - tx) + z[iy + 1, ix + 1] * tx
    out = a * (1.0 - ty) + b * ty
    return np.where(inside, out, np.nan)


#: slope_classes(): 1 the road can follow the ground in any direction, 2 only across the slope
#: (bends, cut and fill), 3 too steep (a tunnel or a viaduct), 0 no data.
FOLLOW, ACROSS, STRUCTURE = 1, 2, 3


def slope_classes(slope, max_slope_deg, steep_deg):
    s = np.asarray(slope)
    out = np.full(s.shape, STRUCTURE, dtype=np.uint8)
    out[s <= steep_deg] = ACROSS
    out[s <= max_slope_deg] = FOLLOW
    out[~np.isfinite(s)] = 0
    return out


def read_godot(prefix):
    """(heights[ny, nx] float32, meta dict, crack depths or None) written by terrain_dem.gd."""
    with open(prefix + ".json", encoding="utf-8") as fh:
        meta = json.load(fh)
    grid = Grid.from_meta(meta)
    z = np.fromfile(prefix + ".f32", dtype="<f4")
    if z.size != grid.nx * grid.ny:
        raise ValueError(f"{prefix}.f32 holds {z.size} values, the grid {grid.nx}×{grid.ny}")
    cracks = None
    if meta.get("cracks"):
        cracks = np.fromfile(prefix + ".cracks.f32", dtype="<f4").reshape(grid.shape)
    return z.reshape(grid.shape), meta, cracks
