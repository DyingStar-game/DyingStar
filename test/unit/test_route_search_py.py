"""The grade-limited road search of the QGIS road tools
(tools/planettech/qgis/export/planet/route_search.py), on synthetic terrains. Needs numpy and scipy:
`python3 test/unit/test_route_search_py.py`.

What it guards: a search that goes straight up a ridge (the game would bore or bridge it all) when
hairpins at the max grade can climb it, and a route judged by the game's own longitudinal profile
(grade_profile.py) mostly on the ground.
"""
import math
import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                                "..", "tools", "planettech", "qgis")))

from export.planet import grade_profile as gp  # noqa: E402
from export.planet import modifier_geom  # noqa: E402
from export.planet import route_search as rs  # noqa: E402
from export.planet import terrain_grid as tg  # noqa: E402

R = 6_356_000.0
M_PER_DEG = R * math.pi / 180.0


def _grid(width_m, height_m, pitch_m, lat0=10.0):
    box = (20.0, 20.0 + width_m / (M_PER_DEG * math.cos(math.radians(lat0))),
           lat0, lat0 + height_m / M_PER_DEG)
    return tg.Grid.for_box(box, R, pitch_m, 10_000_000)[0], box


def _north_m(grid):
    lat = np.repeat(grid.lats[:, None], grid.nx, axis=1)
    return (lat - grid.lats[-1]) * M_PER_DEG


def _profile(route, z, grid, max_grade):
    line = route["line"]
    cum = modifier_geom.cumulative_lengths(line, M_PER_DEG)

    def terrain(a):
        lon, lat = gp.lonlat_at(line, cum, a)
        return float(tg.bilinear(z, grid, np.array([lon]), np.array([lat]))[0])
    return gp.compute(cum[0], cum[-1], terrain, max_grade, True)


class Flat(unittest.TestCase):

    def test_flat_ground_gives_a_near_straight_road(self):
        grid, box = _grid(8000.0, 6000.0, 50.0)
        z = np.zeros(grid.shape)
        a, b = (box[0] + 0.001, box[2] + 0.005), (box[1] - 0.001, box[3] - 0.005)
        r = rs.plan(z, grid, R, [a, b], 0.08)
        straight = rs._dist_m(a, b, R)
        self.assertLess(r["length_m"], 1.03 * straight, "16 neighbours keep a slant road straight")
        self.assertEqual(r["line"][0], a)
        self.assertEqual(r["line"][-1], b)
        self.assertEqual(r["steep_share"], 0.0)


class Ridge(unittest.TestCase):
    """A ridge across the whole area: 600 m up in 2 km (30 %) — no way round."""

    def setUp(self):
        self.grid, box = _grid(6000.0, 8000.0, 25.0)
        north = _north_m(self.grid)
        self.z = np.clip((north - 3000.0) / 2000.0, 0.0, 1.0) * 600.0
        lon_mid = 0.5 * (box[0] + box[1])
        self.a = (lon_mid, box[2] + 1000.0 / M_PER_DEG)
        self.b = (lon_mid, box[3] - 1000.0 / M_PER_DEG)

    def test_hairpins_instead_of_straight_up(self):
        g = math.tan(math.radians(8.0))
        r = rs.plan(self.z, self.grid, R, [self.a, self.b], g)
        straight = rs._dist_m(self.a, self.b, R)
        # 600 m at 14 % is at least 4.3 km on the slope alone, against 2 km straight up.
        self.assertGreater(r["length_m"], straight + 2000.0)
        self.assertLess(r["steep_share"], 0.05, "climbs in bends, not straight up")
        prof = _profile(r, self.z, self.grid, g)
        s = gp.summary(prof)
        self.assertGreater(s["share"][gp.GROUND], 0.85,
                           "the game's own profile keeps the road mostly on the ground")

    def test_a_heavier_structure_weight_never_shortens_the_bends(self):
        g = math.tan(math.radians(8.0))
        soft = rs.plan(self.z, self.grid, R, [self.a, self.b], g, structure_weight=0.5)
        hard = rs.plan(self.z, self.grid, R, [self.a, self.b], g, structure_weight=20.0)
        self.assertGreaterEqual(hard["length_m"], soft["length_m"] - 1.0)
        self.assertLessEqual(hard["steep_share"], soft["steep_share"] + 1e-9)

    def test_waypoints_are_passed_through(self):
        g = math.tan(math.radians(8.0))
        via = (self.a[0] + 1500.0 / (M_PER_DEG * math.cos(math.radians(self.a[1]))),
               0.5 * (self.a[1] + self.b[1]))
        r = rs.plan(self.z, self.grid, R, [self.a, via, self.b], g)
        closest = min(rs._dist_m(p, via, R) for p in r["line"])
        self.assertLess(closest, 2.0 * r["cell_m"])


class Cracks(unittest.TestCase):

    def test_a_chasm_is_crossed_where_it_is_narrow(self):
        grid, box = _grid(6000.0, 6000.0, 25.0)
        north = _north_m(grid)
        east = np.repeat(((grid.lons - grid.lon0) * M_PER_DEG
                          * math.cos(math.radians(box[2])))[None, :], grid.ny, axis=0)
        # An east-west chasm, 400 m wide but only 50 m wide in its eastern part.
        width = np.where(east > 4000.0, 50.0, 400.0)
        cracks = np.where(np.abs(north - 3000.0) < 0.5 * width, 150.0, 0.0)
        z = np.zeros(grid.shape)
        lon = box[0] + 2000.0 / (M_PER_DEG * math.cos(math.radians(box[2])))
        a, b = (lon, box[2] + 500.0 / M_PER_DEG), (lon, box[3] - 500.0 / M_PER_DEG)
        r = rs.plan(z, grid, R, [a, b], 0.08, cracks=cracks, crack_weight=40.0)
        crossing = [p for p in r["line"] if abs((p[1] - grid.lats[-1]) * M_PER_DEG - 3000.0) < 300]
        self.assertTrue(crossing)
        self.assertTrue(any((p[0] - grid.lon0) * M_PER_DEG * math.cos(math.radians(box[2])) > 3500
                            for p in r["line"]), "the road goes round to the narrow crossing")


class StructureLimits(unittest.TestCase):
    """A 300 m deep canyon with sheer walls, from the south edge to 5 km north; the road from its
    west to its east side at 2 km. With structures cheap, it bridges the canyon; with a 300 m max
    bridge, it goes round the canyon's head."""

    def setUp(self):
        self.grid, box = _grid(8000.0, 8000.0, 25.0)
        north = _north_m(self.grid)
        east = np.repeat(((self.grid.lons - self.grid.lon0) * M_PER_DEG
                          * math.cos(math.radians(box[2])))[None, :], self.grid.ny, axis=0)
        canyon = (np.abs(east - 4000.0) < 600.0) & (north < 5000.0)
        self.z = np.where(canyon, 100.0, 400.0)
        clat = math.cos(math.radians(box[2]))
        self.a = (box[0] + 1500.0 / (M_PER_DEG * clat), box[2] + 2000.0 / M_PER_DEG)
        self.b = (box[0] + 6500.0 / (M_PER_DEG * clat), box[2] + 2000.0 / M_PER_DEG)
        self.g = math.tan(math.radians(6.0))

    def _bridges(self, prof):
        return [s["hi"] - s["lo"] for s in prof["segments"] if s["kind"] == gp.BRIDGE]

    def test_without_a_limit_it_bridges(self):
        r = rs.plan_with_limits(self.z, self.grid, R, [self.a, self.b], self.g,
                                structure_weight=0.2)
        self.assertEqual(r["tries"], 1)
        self.assertGreater(max(self._bridges(r["profile"]), default=0.0), 300.0)

    def test_a_max_bridge_sends_it_round_the_head(self):
        r = rs.plan_with_limits(self.z, self.grid, R, [self.a, self.b], self.g,
                                structure_weight=0.2, max_bridge_m=300.0)
        self.assertEqual(r["overlong"], [], "no viaduct over 300 m left")
        self.assertLessEqual(max(self._bridges(r["profile"]), default=0.0), 300.0)
        self.assertGreater(r["tries"], 1)
        top = max(p[1] for p in r["line"])
        self.assertGreater((top - self.grid.lats[-1]) * M_PER_DEG, 5000.0,
                           "the route passes north of the canyon's head")

    def test_overlong_lists_what_is_too_long(self):
        prof = {"segments": [{"kind": gp.BRIDGE, "lo": 0.0, "hi": 500.0},
                             {"kind": gp.TUNNEL, "lo": 500.0, "hi": 600.0},
                             {"kind": gp.GROUND, "lo": 600.0, "hi": 5000.0}]}
        self.assertEqual(len(rs.overlong(prof, 400.0, 0.0)), 1)
        self.assertEqual(len(rs.overlong(prof, 0.0, 50.0)), 1)
        self.assertEqual(len(rs.overlong(prof, 0.0, 0.0)), 0)


class Errors(unittest.TestCase):

    def test_outside_the_terrain(self):
        grid, box = _grid(2000.0, 2000.0, 50.0)
        with self.assertRaises(rs.NoRoute):
            rs.plan(np.zeros(grid.shape), grid, R, [(box[0] - 1.0, box[2]), (box[1], box[3])],
                    0.1)


if __name__ == "__main__":
    unittest.main()
