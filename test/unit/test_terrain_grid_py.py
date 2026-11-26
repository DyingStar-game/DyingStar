"""The road tools' terrain grid (tools/planettech/qgis/export/planet/terrain_grid.py): the grid
both terrain sources share, its georeferencing, and the slope in true metres. numpy only:
`python3 test/unit/test_terrain_grid_py.py`.

What it guards: a slope taken with one scale for the whole lon/lat raster (QGIS's own) reads a
road 2× too steep east-west at 60° of latitude; a grid that disagrees with terrain_dem.gd's by
half a pixel puts the relief 12 m off the road drawn over it.
"""
import json
import math
import os
import shutil
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                                "..", "tools", "planettech", "qgis")))

from export.planet import terrain_grid as tg  # noqa: E402

R = 6_356_000.0


class GridConvention(unittest.TestCase):

    def test_for_box_covers_the_box_from_its_north_west_corner(self):
        g, pitch = tg.Grid.for_box((10.0, 10.2, 20.0, 20.1), R, 25.0, 10_000_000)
        self.assertEqual(pitch, 25.0)
        self.assertAlmostEqual(g.lons[0], 10.0)
        self.assertAlmostEqual(g.lats[0], 20.1)
        self.assertGreaterEqual(g.lons[-1], 10.2 - 1e-12)
        self.assertLessEqual(g.lats[-1], 20.0 + 1e-12)
        # 25 m north-south, and east-west at the mid latitude.
        self.assertAlmostEqual(math.radians(g.dlat) * R, 25.0, places=6)
        self.assertAlmostEqual(math.radians(g.dlon) * R * math.cos(math.radians(20.05)), 25.0,
                               places=6)

    def test_same_grid_as_the_mountain_preview(self):
        from export.planet import mountain_preview as mp
        box = (-17.6, -17.2, 0.8, 1.1)
        g, pitch = tg.Grid.for_box(box, R, 25.0, 4_000_000)
        lons, lats, sp = mp.grid_for_box(box, R, 25.0, 4_000_000)
        self.assertEqual(pitch, sp)
        np.testing.assert_array_equal(g.lons, lons)
        np.testing.assert_array_equal(g.lats, lats)

    def test_coarsened_to_the_sample_ceiling(self):
        g, pitch = tg.Grid.for_box((0.0, 10.0, 0.0, 10.0), R, 25.0, 1_000_000)
        self.assertGreater(pitch, 25.0)
        self.assertLessEqual(g.nx * g.ny, 1_000_000 * 1.05)

    def test_pixel_centres_are_the_nodes(self):
        g = tg.Grid(10.0, 0.01, 5, 20.0, 0.02, 4)
        x0, px, _, y0, _, py = g.geotransform()
        self.assertAlmostEqual(x0 + 0.5 * px, 10.0)
        self.assertAlmostEqual(y0 + 0.5 * py, 20.0)

    def test_godot_argument_keeps_every_digit(self):
        g, _ = tg.Grid.for_box((10.123456789, 10.2, 20.0, 20.1), R, 25.0, 10_000_000)
        p = g.godot_arg().split("=", 1)[1].split(",")
        self.assertEqual(float(p[0]), g.lon0)
        self.assertEqual(float(p[1]), g.dlon)
        self.assertEqual(int(p[2]), g.nx)
        self.assertEqual(float(p[4]), g.dlat)


class Bilinear(unittest.TestCase):

    def test_nodes_exact_plane_linear_outside_nan(self):
        g = tg.Grid(10.0, 0.01, 5, 20.0, 0.01, 4)
        lon, lat = np.meshgrid(g.lons, g.lats)
        z = 3.0 * (lon - 10.0) + 7.0 * (lat - 20.0)
        np.testing.assert_allclose(tg.bilinear(z, g, lon, lat), z)
        self.assertAlmostEqual(float(tg.bilinear(z, g, 10.015, 19.985)), 3.0 * 0.015 - 7.0 * 0.015)
        self.assertTrue(np.isnan(tg.bilinear(z, g, 9.99, 19.99)))

    def test_geotransform_round_trip(self):
        g = tg.Grid(10.0, 0.01, 5, 20.0, 0.02, 4)
        self.assertEqual(tg.Grid.from_geotransform(g.geotransform(), g.nx, g.ny), g)


class Slope(unittest.TestCase):

    def _plane(self, lat0, grade_east, grade_north):
        g, _ = tg.Grid.for_box((10.0, 10.05, lat0, lat0 + 0.05), R, 25.0, 10_000_000)
        lon, lat = np.meshgrid(g.lons, g.lats)
        east_m = np.radians(lon - g.lon0) * R * np.cos(np.radians(lat))
        north_m = np.radians(lat - g.lats[-1]) * R
        return g, grade_east * east_m + grade_north * north_m

    def test_a_plane_rising_northwards(self):
        g, z = self._plane(20.0, 0.0, 0.10)
        s = tg.slope_deg(z, g, R)
        np.testing.assert_allclose(s, math.degrees(math.atan(0.10)), atol=1e-3)

    def test_east_west_at_60_degrees_is_in_true_metres(self):
        g, z = self._plane(60.0, 0.08, 0.0)
        s = tg.slope_deg(z, g, R)
        # A raster-wide scale would read about twice that.
        np.testing.assert_allclose(s[1:-1, 1:-1], math.degrees(math.atan(0.08)), atol=0.05)

    def test_flat_is_zero(self):
        g = tg.Grid(0.0, 0.001, 30, 0.0, 0.001, 20)
        self.assertEqual(float(tg.slope_deg(np.full(g.shape, 123.0), g, R).max()), 0.0)

    def test_classes(self):
        c = tg.slope_classes(np.array([1.0, 8.0, 8.1, 30.0, 31.0, np.nan]), 8.0, 30.0)
        self.assertEqual(c.tolist(), [tg.FOLLOW, tg.FOLLOW, tg.ACROSS, tg.ACROSS, tg.STRUCTURE, 0])


class GodotOutput(unittest.TestCase):

    def test_read_back_what_terrain_dem_writes(self):
        d = tempfile.mkdtemp(prefix="terrain_grid_")
        try:
            g = tg.Grid(10.0, 0.01, 4, 20.0, 0.01, 3)
            z = np.arange(12, dtype="<f4")
            z.tofile(os.path.join(d, "dem.f32"))
            (z * 0 + 7).astype("<f4").tofile(os.path.join(d, "dem.cracks.f32"))
            meta = {"lon0": g.lon0, "dlon": g.dlon, "nx": g.nx, "lat_top": g.lat_top,
                    "dlat": g.dlat, "ny": g.ny, "cracks": True}
            with open(os.path.join(d, "dem.json"), "w") as fh:
                json.dump(meta, fh)
            h, m, cr = tg.read_godot(os.path.join(d, "dem"))
            self.assertEqual(h.shape, (3, 4))
            self.assertEqual(h[0, 3], 3.0)       # row 0 = north, i along the row
            self.assertEqual(h[2, 0], 8.0)
            self.assertEqual(tg.Grid.from_meta(m), g)
            self.assertEqual(float(cr.max()), 7.0)
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
