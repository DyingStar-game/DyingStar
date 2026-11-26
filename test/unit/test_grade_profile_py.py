"""The QGIS road tools' longitudinal profile (tools/planettech/qgis/export/planet/grade_profile.py)
against the game's GradeProfile, through grade_profile_golden.json (written by
tools/planettech/grade_profile_golden.tscn). Stdlib only: `python3 test/unit/test_grade_profile_py.py`.

Exact equality, not a tolerance: the twin repeats the GDScript's float64 operations in the same
order, so any difference is a rule that drifted — the profile panel would then announce a tunnel
the game does not dig.
"""
import json
import math
import os
import sys
import unittest

_QGIS = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                     "tools", "planettech", "qgis"))
sys.path.insert(0, _QGIS)

from export.planet import grade_profile as gp  # noqa: E402

with open(os.path.join(_QGIS, "export", "planet", "grade_profile_golden.json"),
          encoding="utf-8") as _fh:
    GOLDEN = json.load(_fh)


class SameAsTheGame(unittest.TestCase):

    def test_constants(self):
        c = GOLDEN["constants"]
        for name in ("STATION_STEP_M", "WINDOW_M", "TUNNEL_MIN_COVER_M", "GORGE_MIN_M",
                     "MIN_TUNNEL_M", "MIN_GORGE_BETWEEN_TUNNELS_M", "BED_THICKNESS_M",
                     "MIN_SPAN_M", "VIADUCT_MAX_SPAN_M"):
            self.assertEqual(getattr(gp, name), c[name], name)
        self.assertEqual(gp.RAILWAY_MAX_GRADE, c["RAILWAY_MAX_GRADE"])
        self.assertEqual(gp.RAILWAY_CLIMB_AT_MAX_GRADE, c["RAILWAY_CLIMB_AT_MAX_GRADE"])

    def test_every_case_bit_for_bit(self):
        self.assertGreaterEqual(len(GOLDEN["cases"]), 8)
        for case in GOLDEN["cases"]:
            with self.subTest(case=case["name"]):
                if "grade_deg" in case:
                    self.assertEqual(math.tan(math.radians(case["grade_deg"])), case["grade"],
                                     "tan(deg_to_rad) as in RoadTerrain.max_grade")
                p = gp.compute(case["a0"], case["a1"], gp.piecewise_terrain(case["terrain"]),
                               case["grade"], case["climb"])
                self.assertEqual(len(p["stations_along"]), case["stations"])
                self.assertEqual(p["knots_along"], case["knots_along"])
                self.assertEqual(p["knots_z"], case["knots_z"])
                got = [(s["kind"], s["lo"], s["hi"], s["max_depth"], s["max_gap"])
                       for s in p["segments"]]
                want = [(s["kind"], s["lo"], s["hi"], s["max_depth"], s["max_gap"])
                        for s in case["segments"]]
                self.assertEqual(got, want)


class Helpers(unittest.TestCase):

    def test_max_grade_of(self):
        self.assertEqual(gp.max_grade_of("railway"), 0.04)
        self.assertAlmostEqual(gp.max_grade_of("highway", 8), math.tan(math.radians(8)))
        self.assertIsNone(gp.max_grade_of("road", None), "an ungraded road hugs the terrain")
        self.assertIsNone(gp.max_grade_of("path", 10))

    def test_lonlat_at(self):
        cl = [(0.0, 0.0), (1.0, 0.0), (1.0, 2.0)]
        cum = [100.0, 200.0, 400.0]
        self.assertEqual(gp.lonlat_at(cl, cum, 50.0), (0.0, 0.0))
        self.assertEqual(gp.lonlat_at(cl, cum, 150.0), (0.5, 0.0))
        self.assertEqual(gp.lonlat_at(cl, cum, 300.0), (1.0, 1.0))
        self.assertEqual(gp.lonlat_at(cl, cum, 999.0), (1.0, 2.0))

    def test_too_short_is_refused(self):
        self.assertIsNone(gp.compute(0.0, 4.0, lambda a: 0.0, 0.1, True))

    def test_summary(self):
        case = next(c for c in GOLDEN["cases"] if c["name"] == "wide_valley_long_viaduct")
        p = gp.compute(case["a0"], case["a1"], gp.piecewise_terrain(case["terrain"]),
                       case["grade"], case["climb"])
        s = gp.summary(p)
        self.assertAlmostEqual(sum(s["by_kind_m"].values()), s["length_m"])
        self.assertLessEqual(s["steepest_grade"], case["grade"] + 1e-12)
        self.assertEqual(len(s["viaducts"]), 1)
        length, decks, gap = s["viaducts"][0]
        self.assertEqual(decks, math.ceil(length / gp.VIADUCT_MAX_SPAN_M))
        self.assertGreater(gap, 200.0)


if __name__ == "__main__":
    unittest.main()
