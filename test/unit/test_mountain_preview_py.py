#!/usr/bin/env python3
"""The QGIS mountain preview evaluates the relief the game builds.

preview_mountain_contours.py draws elevation contours of the procedural mountains
in QGIS, computed by export/planet/mountain_preview.py — a numpy port of
MountainRelief.offset. A contour that does not match the game would put a road on
a slope that is not there, so this pins the port:

  1. the vectorised hash / value noise / shape equal the scalar twin
     (mountain_noise.py, itself pinned to GDScript by test_mountain_noise_py.py)
     bit for bit;
  2. the full offset — two overlapping ranges (alpine, mesa with a lift), their
     feathered edges, an escarpment ridge on both flanks, a stepped ridge, a point
     exactly on a crest, the ends' taper — equals the values Godot's
     MountainRelief.offset gave for the same features (GDScript path, 4.7.2),
     at two grid pitches (25 m: every octave; 300 m: the fine ones dropped);
  3. the grid / cluster helpers cover every feature.

Regenerate the GODOT_* lists only after a deliberate change of mountain_relief.gd.

Run:  python3 test/unit/test_mountain_preview_py.py
"""

import math
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                "tools", "planettech", "qgis"))

try:
    import numpy as np
except ImportError:  # pragma: no cover
    print("SKIP test_mountain_preview_py: numpy absent")
    sys.exit(0)

from export.planet import mountain_noise as mn  # noqa: E402
from export.planet import mountain_preview as mp  # noqa: E402

RADIUS = 3467000.0

RING = [(-103.2, -22.95), (-102.85, -22.9), (-102.8, -22.65), (-103.0, -22.6), (-103.25, -22.7)]
ZONES = [
    (RING, {"style": "alpine", "seed": 3}),
    ([(x + 0.1, y + 0.05) for x, y in RING], {"style": "mesa", "seed": 11, "lift_m": 200.0}),
]
RIDGES = [
    ([(-103.4, -23.7), (-103.6, -23.62), (-103.75, -23.66)], {"style": "escarpment", "seed": 4}),
    ([(-103.1, -23.3), (-102.95, -23.1)], {"style": "stepped", "seed": 4}),
]

POINTS = [
    (-103.02, -22.77), (-102.95, -22.72), (-103.1, -22.8),
    (-103.02, -22.915), (-103.02, -22.905), (-103.3, -22.8),
    (-102.9, -22.68), (-103.48916872981484, -23.637282722792328), (-103.4935012378889, -23.6463696336754),
    (-103.49711166128395, -23.65394205941129), (-103.49927791532099, -23.65848551485282), (-103.5, -23.66),
    (-103.50108312701852, -23.662271727720768), (-103.50361042339506, -23.66757242573589),
    (-103.50794293146912, -23.676659336618957),
    (-103.51227543954319, -23.685746247502028), (-103.68256305230578, -23.616198845202913),
    (-103.67953783138347, -23.62571930712175),
    (-103.67701681394821, -23.633653025387442), (-103.67550420348705, -23.638413256346862), (-103.675, -23.64),
    (-103.67424369476942, -23.64238011547971), (-103.67247898256474, -23.647933718265698),
    (-103.66945376164242, -23.65745418018453),
    (-103.6664285407201, -23.666974642103366), (-103.39800000000001, -23.698999999999998),
    (-103.00279481864487, -23.21406936564619),
    (-103.01167689118692, -23.208441619387713), (-103.0190786183053, -23.203751830838986),
    (-103.02351965457633, -23.200937957709748),
    (-103.025, -23.200000000000003), (-103.02722051813552, -23.198593063435386),
    (-103.03240172711838, -23.195310211451275),
    (-103.04128379966043, -23.1896824651928), (-103.0501658722025, -23.184054718934323), (-103.098, -23.299),
]

# MountainRelief.offset(HEALPix.lonlat2vec(lon, lat), RADIUS, zones, ridges, pitch) in Godot.
GODOT_25 = [
    601.0825817733955, 780.8559930266827, 482.07448264651043, 18.732217606852085,
    48.069166509012824, 0.0, 821.4513172214645, 0.0,
    0.0, 0.0, 241.97975373922372, 289.8455492238337,
    279.47207745326693, 228.72171594110233, 109.86303144347978, 4.7392363788991565,
    0.0, 0.0, 0.0, 182.51404812783505,
    267.1935836595679, 253.39634548920134, 208.0550017469536, 100.71848362415359,
    0.0, 0.0, 0.0, 0.0,
    180.0, 300.0, 360.0, 300.0,
    240.0, 60.0, 0.0, 0.0,
]
GODOT_300 = [
    597.4122536443062, 773.5334538772292, 500.6490446966783, 17.97410501288475,
    44.150190285246545, 0.0, 829.2820068593674, 0.0,
    0.0, 0.0, 241.97975373922372, 289.8455492238337,
    279.47207745326693, 228.72171594110233, 109.86303144347978, 4.7392363788991565,
    0.0, 0.0, 0.0, 182.51404812783505,
    267.1935836595679, 253.39634548920134, 208.0550017469536, 100.71848362415359,
    0.0, 0.0, 0.0, 0.0,
    180.0, 300.0, 360.0, 300.0,
    240.0, 60.0, 0.0, 0.0,
]


def _features():
    feats = [mp.prepare_zone(ring, props) for ring, props in ZONES]
    feats += [mp.prepare_ridge(pts, props, RADIUS) for pts, props in RIDGES]
    return feats


class TestNoiseEqualsScalarTwin(unittest.TestCase):
    def setUp(self):
        self.rng = np.random.default_rng(1)

    def test_hash(self):
        ix = self.rng.integers(-2 ** 40, 2 ** 40, 500)
        iy = self.rng.integers(-2 ** 31, 2 ** 31, 500)
        iz = self.rng.integers(-5000, 5000, 500)
        for seed in (0, 7, -3, 123456):
            h = mp.hash_v(ix, iy, iz, seed)
            for k in range(500):
                self.assertEqual(int(h[k]), mn.hash_i(int(ix[k]), int(iy[k]), int(iz[k]), seed))

    def test_vnoise(self):
        x, y, z = (self.rng.uniform(-3000.0, 3000.0, 500) for _ in range(3))
        v = mp.vnoise_v(x, y, z, 42)
        for k in range(500):
            self.assertEqual(v[k], mn.vnoise(x[k], y[k], z[k], 42))

    def test_shape_every_preset(self):
        d = self.rng.normal(size=(200, 3))
        d /= np.linalg.norm(d, axis=1)[:, None]
        for style in mp.PRESETS:
            zone = mp.prepare_zone(RING, {"style": style, "seed": 5})
            for pitch in (10.0, 400.0):
                s = mp.shape_v(d[:, 0], d[:, 1], d[:, 2], RADIUS, zone, pitch)
                for k in range(200):
                    self.assertEqual(s[k], mn.shape(*d[k], RADIUS, zone, pitch), style)

    def test_shape_too_coarse_is_none(self):
        zone = mp.prepare_zone(RING, {"style": "alpine"})
        self.assertIsNone(mp.shape_v(np.ones(1), np.zeros(1), np.zeros(1), RADIUS, zone,
                                     zone["wavelength_m"] * 0.5))


class TestOffsetEqualsGodot(unittest.TestCase):
    def _check(self, pitch, expected):
        pts = np.asarray(POINTS)
        got = mp.offset_v(pts[:, 0], pts[:, 1], RADIUS, _features(), pitch)
        for k, (g, e) in enumerate(zip(got, expected)):
            self.assertAlmostEqual(g, e, delta=1e-6, msg="point %d %r" % (k, POINTS[k]))

    def test_full_detail(self):
        self._check(25.0, GODOT_25)

    def test_coarse_pitch(self):
        self._check(300.0, GODOT_300)

    def test_reference_covers_every_case(self):
        # Core of a range, its feather band, both flanks of a ridge, terraces.
        self.assertGreater(GODOT_25[1], 700.0)
        self.assertTrue(0.0 < GODOT_25[3] < GODOT_25[4] < 100.0)
        self.assertGreater(GODOT_25[12], 0.0)
        self.assertGreater(GODOT_25[21], 0.0)
        self.assertIn(300.0, GODOT_25)


class TestGrid(unittest.TestCase):
    def test_clusters_group_overlaps_only(self):
        feats = _features()
        groups = mp.cluster_boxes(feats, RADIUS, 500.0)
        sizes = sorted(len(f) for _, f in groups)
        # The two ranges overlap; the two ridges stand apart from them and each other.
        self.assertEqual(sizes, [1, 1, 2])
        for box, members in groups:
            for f in members:
                b = f["bbox"]
                self.assertTrue(box[0] <= b[0] and b[1] <= box[1] and box[2] <= b[2] and b[3] <= box[3])

    def test_intersect_boxes(self):
        self.assertEqual(mp.intersect_boxes((0.0, 2.0, 0.0, 2.0), (1.0, 3.0, -1.0, 1.5)), (1.0, 2.0, 0.0, 1.5))
        self.assertIsNone(mp.intersect_boxes((0.0, 1.0, 0.0, 1.0), (2.0, 3.0, 0.0, 1.0)))

    def test_grid_spacing_and_cap(self):
        box = (-103.3, -102.7, -23.0, -22.5)
        lons, lats, spacing = mp.grid_for_box(box, RADIUS, 50.0, 10 ** 7)
        self.assertEqual(spacing, 50.0)
        m_per_deg = RADIUS * math.pi / 180.0
        self.assertAlmostEqual((lats[0] - lats[1]) * m_per_deg, 50.0, places=6)
        self.assertGreaterEqual(lons[-1], box[1])
        self.assertLessEqual(lats[-1], box[2])
        lons, lats, spacing = mp.grid_for_box(box, RADIUS, 50.0, 10000)
        self.assertGreater(spacing, 50.0)
        self.assertLessEqual(len(lons) * len(lats), 10000 * 1.1)

    def test_evaluate_grid_matches_pointwise(self):
        feats = _features()
        lons = np.linspace(-103.1, -102.9, 7)
        lats = np.linspace(-22.7, -22.9, 5)
        grid = mp.evaluate_grid(lons, lats, RADIUS, feats, 100.0, ground=lambda lo, la: lo * 0.0 + 10.0)
        self.assertEqual(grid.shape, (5, 7))
        ref = mp.offset_v(np.array([lons[3]]), np.array([lats[2]]), RADIUS, feats, 100.0)[0]
        self.assertAlmostEqual(grid[2, 3], ref + 10.0, places=9)

    def test_bilinear_equirect(self):
        # 8 x 4 global raster whose value is the column index: wraps across the antimeridian.
        arr = np.tile(np.arange(8, dtype=np.float64), (4, 1))
        gt = (-180.0, 45.0, 0.0, 90.0, 0.0, -45.0)
        v = mp.bilinear_equirect(arr, gt, np.array([-157.5, -135.0, 157.5, 180.0]), np.zeros(4))
        self.assertEqual(v.tolist(), [0.0, 0.5, 7.0, 3.5])


if __name__ == "__main__":
    unittest.main()
