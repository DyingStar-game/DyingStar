"""Unit tests of village_snaps.py: the roads are cut out of the villages and led to their snaps.

    python -m unittest tools/planettech/qgis/export/planet/test_village_snaps.py
"""

import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import village_snaps as vs  # noqa: E402

RADIUS = 6356000.0
MPD = RADIUS * math.pi / 180.0
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


class EulerTest(unittest.TestCase):
    def test_yaw_only(self):
        z = vs.basis_z_from_euler(0.0, math.pi / 2.0, 0.0)  # +Z turned 90° about Y → +X
        for a, b in zip(z, (1.0, 0.0, 0.0)):
            self.assertAlmostEqual(a, b, places=9)


if __name__ == "__main__":
    unittest.main()
