"""Rocky terrain, Python side: the twin's golden values (shared with
test/unit/test_rock_field_relief.gd), the export resolution of the presets and
the ROCKY part of the modifier pack.

Run: python3 test/unit/test_rock_field_relief_py.py
"""
import ast
import math
import os
import re
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "planettech", "qgis"))

from export.planet import dsmp                                   # noqa: E402
from export.planet import rock_field_noise as rn                 # noqa: E402
from export.planet import rocky_terrain as rt                    # noqa: E402
from export.planet.dsmp_strings import StringTable               # noqa: E402

GOLDEN_RADIUS = 3467000.0
RING = [(-103.0, -23.0), (-102.9, -23.0), (-102.9, -22.9), (-103.0, -22.9)]


def _norm(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    return (v[0] / n, v[1] / n, v[2] / n)


def golden_record():
    c = _norm((0.3, 0.5, 0.8))
    return dict(cell_m=150.0, step_m=12.0, riser=0.25, joint_depth_m=3.0, joint_width_m=30.0,
                joint_mean_m=1.0, butte_rate=0.3, butte_height_m=40.0, butte_cell_m=600.0,
                butte_wall_m=50.0, butte_mean_m=0.5, seed=7, cx=c[0], cy=c[1], cz=c[2],
                wx=0.6, wy=0.0, wz=-0.8, k=0.5, dpx=0.1, dpy=-0.05, dpz=0.02)


class TestRockFieldNoise(unittest.TestCase):
    GOLDEN = {
        0.0: [26.443037170598878, 2.5718848638778127, -3.708317237013702, 1.968365625182191,
               0.02666837863876026, -3.5847115675763974, -1.1980966065874548,
               -0.16047086626908502],
        25.0: [26.443037170598878, 2.5718848638778127, -3.708317237013702, 1.968365625182191,
               0.02666837863876026, -3.5847115675763974, -1.1980966065874548,
               -0.16047086626908502],
        60.0: [27.47338218262058, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5],
    }

    def test_offset_golden(self):
        f = golden_record()
        for pitch, want in self.GOLDEN.items():
            for i in range(8):
                d = _norm((0.3 + 0.0001 * i, 0.5 - 0.00013 * i, 0.8 + 0.00007 * i))
                got = rn.field_offset(d[0], d[1], d[2], GOLDEN_RADIUS, f, pitch, 1000.0 + 37.5 * i)
                self.assertEqual(got, want[i], "pitch %s point %d" % (pitch, i))

    def test_chalk_knobs_golden(self):
        f = golden_record()
        f.update(step_m=0.0, joint_depth_m=0.0, joint_mean_m=0.0, butte_rate=0.0,
                 butte_height_m=0.0, butte_mean_m=0.0, dpx=0.0, dpy=0.0, dpz=0.0,
                 lump_m=5.0, lump_wavelength_m=160.0)
        want = {25.0: [-0.17320621486957039, -2.761124710363702, -3.791354638811648,
                       -3.297374426876215],
                60.0: [0.18393195299612142, -2.5375770651884686, -3.6749888031056717,
                       -4.853436800186989],
                100.0: [0.0, 0.0, 0.0, 0.0]}
        for pitch, vals in want.items():
            for i in range(4):
                d = _norm((0.3 + 0.0001 * i, 0.5 - 0.00013 * i, 0.8 + 0.00007 * i))
                self.assertEqual(rn.field_offset(*d, GOLDEN_RADIUS, f, pitch, 1000.0), vals[i])

    def test_chalk_style_has_knobs_only(self):
        r = rt.resolve_rocky({"ruggedness": "very_rugged", "style": "chalk"}, RING, "t")
        self.assertEqual(r["type"], rt.STYLES.index("chalk"))
        self.assertEqual((r["step_m"], r["joint_depth_m"], r["butte_rate"]), (0.0, 0.0, 0.0))
        self.assertEqual(r["lump_m"], 8.0)

    def test_voronoi_golden(self):
        c1, c2, e = rn.voronoi(1234.56, -789.01, 42.42, 7)
        self.assertEqual(c1, (1234, -790, 42))
        self.assertEqual(c2, (1235, -790, 42))
        self.assertEqual(e, 0.19644441893865838)

    def test_terms_dropped_past_their_cell(self):
        f = golden_record()
        d = _norm((0.3, 0.5, 0.8))
        self.assertEqual(rn.field_offset(*d, GOLDEN_RADIUS, f, 200.0, 1000.0), 0.0)
        f["butte_rate"] = 0.0
        self.assertEqual(rn.field_offset(*d, GOLDEN_RADIUS, f, 50.0, 1000.0), 0.0)


class TestResolve(unittest.TestCase):
    def test_every_level_resolves_and_flat_stays_flat(self):
        for i, level in enumerate(rt.LEVELS):
            for style in rt.STYLES:
                r = rt.resolve_rocky({"ruggedness": level, "style": style}, RING, "t")
                self.assertEqual(r["level"], i)
                self.assertEqual(r["ruggedness"], level)
                self.assertIsInstance(r["seed"], int)
                self.assertIsInstance(r["cell_m"], float)
                self.assertGreaterEqual(r["feather_m"], 250.0)
                if level == "flat":
                    self.assertEqual(r["step_m"], 0.0)
                    self.assertEqual(r["butte_rate"], 0.0)
                    self.assertEqual(r["joint_mean_m"], 0.0)

    def test_overrides_win_and_clamps_hold(self):
        r = rt.resolve_rocky({"ruggedness": "rugged", "cell_m": 300.0, "riser": 5.0,
                              "elongation": 50.0, "seed": 42}, RING, "t")
        self.assertEqual(r["cell_m"], 300.0)
        self.assertEqual(r["riser"], 1.0)
        self.assertAlmostEqual(r["k"], 1.0 - 1.0 / rt.ELONGATION_MAX)
        self.assertEqual(r["seed"], 42)

    def test_vectors_are_unit_and_tangent(self):
        r = rt.resolve_rocky({"ruggedness": "medium", "style": "strata"}, RING, "t")
        c = (r["cx"], r["cy"], r["cz"])
        w = (r["wx"], r["wy"], r["wz"])
        self.assertAlmostEqual(sum(x * x for x in c), 1.0, places=12)
        self.assertAlmostEqual(sum(x * x for x in w), 1.0, places=12)
        self.assertAlmostEqual(sum(a * b for a, b in zip(c, w)), 0.0, places=12)
        dp = (r["dpx"], r["dpy"], r["dpz"])
        tan = math.sqrt(sum(x * x for x in dp))
        self.assertGreater(tan, math.tan(math.radians(7.9)), "strata dip 8-20°")
        self.assertLess(tan, math.tan(math.radians(20.1)))

    def test_auto_values_are_stable(self):
        a = rt.resolve_rocky({"ruggedness": "rugged"}, RING, "tarsis_8")
        b = rt.resolve_rocky({"ruggedness": "rugged"}, RING, "tarsis_8")
        self.assertEqual(a, b)
        c = rt.resolve_rocky({"ruggedness": "rugged"}, RING, "tarsis_3")
        self.assertNotEqual(a["seed"], c["seed"])

    def test_presets_match_the_gdscript_debug_copy(self):
        with open(os.path.join(_REPO, "scenes", "planet", "rock_field_relief.gd"),
                  encoding="utf-8") as fh:
            src = fh.read()
        m = re.search(r"const PRESETS := (\{.*?\n\})", src, re.S)
        self.assertIsNotNone(m)
        gd = ast.literal_eval(m.group(1))
        self.assertEqual(gd, rt.PRESETS)
        m = re.search(r"const INTENSITY: Array\[float\] = (\[[^\]]*\])", src)
        self.assertEqual(tuple(ast.literal_eval(m.group(1))), rt.INTENSITY)
        m = re.search(r"const LEVELS: Array\[String\] = (\[[^\]]*\])", src)
        self.assertEqual(tuple(ast.literal_eval(m.group(1))), rt.LEVELS)
        m = re.search(r"const STYLES: Array\[String\] = (\[[^\]]*\])", src)
        self.assertEqual(tuple(ast.literal_eval(m.group(1))), rt.STYLES)
        m = re.search(r"const CHALK_LUMP_M: Array\[float\] = (\[[^\]]*\])", src)
        self.assertEqual(tuple(ast.literal_eval(m.group(1))), rt.CHALK_LUMP_M)


class TestPart(unittest.TestCase):
    def test_part_tiles_the_zone_down_to_the_export_level(self):
        table = StringTable([])
        levels, manifest = rt.build_rocky_part(
            [{"ring": RING, "props": {"ruggedness": "rugged", "style": "yardang"}}],
            6356000.0, 64, 8192, table, verbose=False, planet_name="t")
        self.assertEqual(manifest["kind"], "rocky")
        self.assertEqual(manifest["levels"][-1], 64)
        self.assertEqual(manifest["counts"]["features"], 1)
        self.assertTrue(all(tiles for _ns, tiles in levels))
        self.assertEqual(dsmp.KIND_NAMES[dsmp.KIND_ROCKY], "rocky")
        self.assertIn("rocky_terrain", table.as_list())


if __name__ == "__main__":
    unittest.main()
