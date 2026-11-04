"""Unit tests of village_snaps.py: the roads are cut out of the villages and led to their snaps.

    python -m unittest tools/planettech/qgis/export/planet/test_village_snaps.py

GoldenTest checks the Python frames against the game's own (village_snaps_golden.json, written by
tools/planettech/village_snaps_golden.tscn); it is skipped while that fixture is missing.
"""

import json
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import village_snaps as vs  # noqa: E402

RADIUS = 6356000.0
MPD = RADIUS * math.pi / 180.0
GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "village_snaps_golden.json")
# How far the Python may put a layout point from where the game puts it (m). Both compute the same
# frame in double precision: anything above a millimetre is a formula that drifted, not rounding.
GOLDEN_TOLERANCE_M = 0.001
# A village on the equator at lon 0, heading north-up (no rotation): its frame's +X points along
# (0, 0, −1)·… — the test reads positions back through the village itself, so the frame's exact
# orientation never needs to be written here.
LAYOUT = {
    "footprint": {"cx": 0.0, "cz": 0.0, "hx": 100.0, "hz": 60.0},
    "snaps": [
        {"name": "RoadEast", "kind": "road", "position": [100.0, 0.0, 0.0], "forward": [1.0, 0.0, 0.0]},
        {"name": "RoadWest", "kind": "road", "position": [-100.0, 0.0, 0.0], "forward": [-1.0, 0.0, 0.0]},
        {"name": "PathSouth", "kind": "path", "position": [0.0, 0.0, 60.0], "forward": [0.0, 0.0, 1.0]},
    ],
}


def _village():
    return vs.Village("M0002", vs.vec_of(0.0, 0.0), (0.0, 0.0, 0.0), LAYOUT, RADIUS)


def _line(v, pts):
    """A centreline through the village's local (x, z) points."""
    return [v.lonlat_at(x, z) for x, z in pts]


def _close(a, b, m=0.5):
    return vs._m_between(a, b, MPD) <= m


class VillageFrameTest(unittest.TestCase):
    def test_lonlat_round_trip(self):
        for lon, lat in [(0.0, 0.0), (12.5, -33.0), (-170.0, 61.0)]:
            back = vs.lonlat_of(vs.vec_of(lon, lat))
            self.assertAlmostEqual(back[0], lon, places=9)
            self.assertAlmostEqual(back[1], lat, places=9)

    def test_local_round_trip(self):
        v = _village()
        x, z = v.local(v.lonlat_at(37.0, -21.0))
        self.assertAlmostEqual(x, 37.0, places=3)
        self.assertAlmostEqual(z, -21.0, places=3)

    def test_inside(self):
        v = _village()
        self.assertTrue(v.inside(v.lonlat_at(99.0, 59.0)))
        self.assertFalse(v.inside(v.lonlat_at(101.0, 0.0)))


class RerouteTest(unittest.TestCase):
    def test_a_road_far_from_any_village_is_untouched(self):
        v = _village()
        line = _line(v, [(-2000.0, 1000.0), (2000.0, 1000.0)])
        self.assertEqual(vs.reroute(line, "road", [v], MPD), [line])

    def test_a_road_through_the_village_is_cut_and_led_to_both_snaps(self):
        v = _village()
        line = _line(v, [(-400.0, 10.0), (400.0, 10.0)])
        pieces = vs.reroute(line, "road", [v], MPD)
        self.assertEqual(len(pieces), 2, "one piece on each side")
        west, east = sorted(pieces, key=lambda p: v.local(p[0])[0])
        self.assertTrue(_close(west[-1], v.lonlat_at(-100.0, 0.0)), "the west piece ends on the west snap")
        self.assertTrue(_close(east[0], v.lonlat_at(100.0, 0.0)), "the east piece starts on the east snap")
        for piece in pieces:
            for p in piece[1:-1]:
                self.assertFalse(v.inside(p), "nothing of the road runs through the village")

    def test_a_road_goes_round_to_a_road_snap_not_to_the_path_snap(self):
        v = _village()
        line = _line(v, [(0.0, 400.0), (0.0, 20.0)])  # comes from the south, where only a path may join
        piece = vs.reroute(line, "road", [v], MPD)[0]
        self.assertTrue(_close(piece[-1], v.lonlat_at(100.0, 0.0)) or _close(piece[-1], v.lonlat_at(-100.0, 0.0)),
                        "it ends on a road snap")
        for p in piece[:-1]:
            self.assertFalse(v.inside(p), "round the village, never through it")

    def test_with_no_snap_of_its_kind_a_road_stops_at_the_edge(self):
        v = vs.Village("M0003", vs.vec_of(0.0, 0.0), (0.0, 0.0, 0.0),
                       {"footprint": LAYOUT["footprint"], "snaps": [LAYOUT["snaps"][2]]}, RADIUS)
        piece = vs.reroute(_line(v, [(0.0, 400.0), (0.0, 20.0)]), "road", [v], MPD)[0]
        x, z = v.local(piece[-1])
        self.assertAlmostEqual(z, 60.0, delta=0.5, msg="it stops at the footprint's edge")

    def test_a_trail_joins_a_path_snap(self):
        v = _village()
        line = _line(v, [(30.0, 400.0), (30.0, 0.0)])
        piece = vs.reroute(line, "trail", [v], MPD)[0]
        self.assertTrue(_close(piece[-1], v.lonlat_at(0.0, 60.0)), "a trail is a path")
        self.assertTrue(_close(piece[-2], v.lonlat_at(0.0, 60.0 + vs.APPROACH_M)), "through the approach point")

    def test_a_long_segment_cannot_jump_over_the_village(self):
        v = _village()
        line = _line(v, [(-1000.0, 0.0), (1000.0, 0.0)])  # two vertices, both far outside
        self.assertEqual(len(vs.reroute(line, "road", [v], MPD)), 2)

    def test_a_road_starting_inside_leaves_from_the_snap(self):
        v = _village()
        line = _line(v, [(0.0, 0.0), (500.0, 0.0)])
        pieces = vs.reroute(line, "road", [v], MPD)
        self.assertEqual(len(pieces), 1)
        self.assertTrue(_close(pieces[0][0], v.lonlat_at(100.0, 0.0)))

    def test_a_road_through_two_touching_villages_skips_the_seam(self):
        a = _village()
        # The second village stands right east of the first: their footprints share the x = 100 edge.
        b = vs.Village("M0004", vs.vec_of(*a.lonlat_at(200.0, 0.0)), (0.0, 0.0, 0.0), LAYOUT, RADIUS)
        line = _line(a, [(-400.0, 10.0), (600.0, 10.0)])
        pieces = vs.reroute(line, "road", [a, b], MPD)
        self.assertEqual(len(pieces), 2, "in before the first, out after the second, nothing between")
        west, east = sorted(pieces, key=lambda p: a.local(p[0])[0])
        self.assertTrue(_close(west[-1], a.lonlat_at(-100.0, 0.0)), "the west piece ends on the first's west snap")
        self.assertTrue(_close(east[0], b.lonlat_at(100.0, 0.0)), "the east piece starts on the second's east snap")


class EulerTest(unittest.TestCase):
    def test_yaw_only(self):
        z = vs.basis_z_from_euler(0.0, math.pi / 2.0, 0.0)  # +Z turned 90° about Y → +X
        for a, b in zip(z, (1.0, 0.0, 0.0)):
            self.assertAlmostEqual(a, b, places=9)


@unittest.skipUnless(os.path.exists(GOLDEN),
                     "no village_snaps_golden.json: run "
                     "godot --headless --path . res://tools/planettech/village_snaps_golden.tscn")
class GoldenTest(unittest.TestCase):
    """The Python agrees with the game: HEALPix.lonlat2vec, Basis.from_euler (YXZ), the frame
    PoiVillages._stand_on_ground stands a village in, and the RoadSnap kind names."""

    @classmethod
    def setUpClass(cls):
        with open(GOLDEN, encoding="utf-8") as f:
            cls.golden = json.load(f)

    def test_lonlat2vec(self):
        for g in self.golden["lonlat2vec"]:
            for a, b in zip(vs.vec_of(g["lon"], g["lat"]), g["vec"]):
                self.assertAlmostEqual(a, b, places=12, msg="lon %s lat %s" % (g["lon"], g["lat"]))

    def test_euler_z(self):
        for v in self.golden["villages"]:
            for a, b in zip(vs.basis_z_from_euler(*v["rotation"]), v["euler_z"]):
                self.assertAlmostEqual(a, b, places=12, msg=v["name"])

    def test_layout_points_land_where_the_game_puts_them(self):
        mpd = self.golden["radius_m"] * math.pi / 180.0
        layout = {"footprint": {"cx": 0.0, "cz": 0.0, "hx": 1.0, "hz": 1.0}, "snaps": []}
        for g in self.golden["villages"]:
            v = vs.Village(g["name"], tuple(g["position"]), tuple(g["rotation"]), layout, self.golden["radius_m"])
            for p in g["points"]:
                where = "%s (%s, %s)" % (g["name"], p["x"], p["z"])
                self.assertLessEqual(vs._m_between(v.lonlat_at(p["x"], p["z"]), p["lonlat"], mpd),
                                     GOLDEN_TOLERANCE_M, where)
                x, z = v.local(p["lonlat"])
                self.assertAlmostEqual(x, p["x"], delta=GOLDEN_TOLERANCE_M, msg=where)
                self.assertAlmostEqual(z, p["z"], delta=GOLDEN_TOLERANCE_M, msg=where)

    def test_kind_names(self):
        self.assertEqual(set(vs.KIND_OF_ROAD_TYPE.values()), set(self.golden["snap_kinds"]),
                         "every snap kind the game has, and no other")
        for k in self.golden["village_road_kinds"]:
            self.assertEqual(vs.KIND_OF_ROAD_TYPE.get(k), k, "a VillageRoad's road_type joins its own snaps")


if __name__ == "__main__":
    unittest.main()
