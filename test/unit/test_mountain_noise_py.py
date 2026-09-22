"""Golden values shared with test/unit/test_mountain_noise.gd.

Run: python3 test/unit/test_mountain_noise_py.py
"""
import math
import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "..", "tools", "planettech", "qgis",
                                "export", "planet"))
import mountain_noise as mn  # noqa: E402


class TestMountainNoise(unittest.TestCase):
    def test_hash_golden(self):
        self.assertEqual(mn.hash_i(0, 0, 0, 0), 3348245848)
        self.assertEqual(mn.hash_i(1, 2, 3, 4), 2416401439)
        self.assertEqual(mn.hash_i(-1, -2, -3, 7), 3867037789)
        self.assertEqual(mn.hash_i(123456, -654321, 42, 99), 2879151037)
        self.assertEqual(mn.hash_i(2 ** 31, -2 ** 31, 5, 1), 2769678470)
        self.assertEqual(mn.hash_i(7, 7, 7, -3), 810817105)

    def test_vnoise_golden(self):
        self.assertAlmostEqual(mn.vnoise(0.5, 0.5, 0.5, 0), 0.38864316791296005, places=15)
        self.assertAlmostEqual(mn.vnoise(1.25, -3.75, 2.5, 1), 0.22107108201646497, places=15)
        self.assertAlmostEqual(mn.vnoise(1000.125, 2000.375, -3000.625, 42),
                               0.6301147014547613, places=15)
        self.assertAlmostEqual(mn.vnoise(-0.001, 0.999, 12.345, 7),
                               0.5109848547258147, places=15)

    def test_shape_golden(self):
        d = (0.3, 0.5, 0.8)
        n = math.sqrt(sum(c * c for c in d))
        d = tuple(c / n for c in d)
        prm = dict(wavelength_m=6000.0, octaves=7, persistence=0.45, ridge=0.6,
                   exponent=1.5, warp=0.0, seed=3)
        self.assertAlmostEqual(mn.shape(*d, 3467000.0, prm, 25.0), 0.36241033415342655, places=14)
        self.assertAlmostEqual(mn.shape(*d, 3467000.0, prm, 1600.0), 0.3376137534106668, places=14)
        self.assertEqual(mn.shape(*d, 3467000.0, prm, 3000.0), -1.0)

    def test_terrace(self):
        self.assertEqual(mn.terrace(137.0, 50.0, 0.2), 100.0)
        self.assertAlmostEqual(mn.terrace(199.0, 50.0, 0.2), 198.6, places=9)


if __name__ == "__main__":
    unittest.main()
