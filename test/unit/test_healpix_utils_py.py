#!/usr/bin/env python3
"""
Unit tests for the pure-Python HEALPix of tools/planettech/qgis/healpix_utils.py -- the one the
planet exporter uses when healpy is not installed (the CI image, a QGIS without it).

Its vec2pix_nest put about half the directions of the equatorial belt on the wrong base face (the
face column was (jp + nside) // (2 * nside), not jp // nside, a bug the game's healpix.gd had
fixed), and its neighbours missed some near the corners of the base faces. An export made without
healpy was wrong; nothing said so.

Pure stdlib + numpy; compares with healpy as well when it is installed.

    python3 test/unit/test_healpix_utils_py.py
"""
import math
import os
import random
import sys
import unittest

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "planettech", "qgis"))

import numpy as np  # noqa: E402

import healpix_utils as hpx  # noqa: E402

HAS_HEALPY = hpx.HAS_HEALPY


class PurePython(unittest.TestCase):
    """Every test runs the pure-Python path, healpy installed or not."""

    def setUp(self) -> None:
        hpx.HAS_HEALPY = False

    def tearDown(self) -> None:
        hpx.HAS_HEALPY = HAS_HEALPY

    def test_a_pixel_s_centre_falls_in_that_pixel(self) -> None:
        for nside in (1, 2, 4, 8, 16, 32):
            for ipix in range(12 * nside * nside):
                x, y, z = hpx.pix2vec_nest(nside, ipix)
                self.assertEqual(hpx.vec2pix_nest(nside, x, y, z), ipix, "n%d p%d" % (nside, ipix))

    def test_the_vectorized_lookup_is_the_scalar_one(self) -> None:
        rng = random.Random(7)
        xs, ys, zs = [], [], []
        for _ in range(3000):
            y = rng.uniform(-1.0, 1.0)
            t = rng.uniform(0.0, 2.0 * math.pi)
            s = math.sqrt(1.0 - y * y)
            xs.append(s * math.cos(t))
            ys.append(y)
            zs.append(s * math.sin(t))
        for nside in (1, 4, 64, 1024):
            got = hpx.vec2pix_nest_vectorized(nside, np.array(xs), np.array(ys), np.array(zs))
            want = [hpx.vec2pix_nest(nside, x, y, z) for x, y, z in zip(xs, ys, zs)]
            self.assertEqual([int(v) for v in got], want, "n%d" % nside)

    def test_neighbours_are_mutual_and_eight_but_round_a_base_corner(self) -> None:
        # From n2: at n1 the twelve base pixels touch so closely that neighbours coincide.
        for nside in (2, 4, 16):
            npix = 12 * nside * nside
            nbs = {p: set(hpx.get_neighbor_pixels(nside, p)) for p in range(npix)}
            for p, around in nbs.items():
                self.assertIn(len(around), (7, 8), "n%d p%d: %s" % (nside, p, sorted(around)))
                self.assertNotIn(p, around)
                for q in around:
                    self.assertIn(p, nbs[q], "n%d: p%d next to p%d but not back" % (nside, p, q))


@unittest.skipUnless(HAS_HEALPY, "healpy not installed")
class SameAsHealpy(unittest.TestCase):
    def _both(self, fn, *args):
        hpx.HAS_HEALPY = True
        a = fn(*args)
        hpx.HAS_HEALPY = False
        b = fn(*args)
        hpx.HAS_HEALPY = HAS_HEALPY
        return a, b

    def test_lookup_and_neighbours_match_healpy(self) -> None:
        rng = random.Random(3)
        for nside in (1, 4, 16, 64, 1024, 8192):
            for _ in range(2000):
                y = rng.uniform(-1.0, 1.0)
                t = rng.uniform(0.0, 2.0 * math.pi)
                s = math.sqrt(1.0 - y * y)
                a, b = self._both(hpx.vec2pix_nest, nside, s * math.cos(t), y, s * math.sin(t))
                self.assertEqual(a, b, "n%d" % nside)
            for ipix in rng.sample(range(12 * nside * nside), min(600, 12 * nside * nside)):
                a, b = self._both(hpx.get_neighbor_pixels, nside, ipix)
                self.assertEqual(sorted(a), sorted(b), "n%d p%d" % (nside, ipix))


if __name__ == "__main__":
    unittest.main()
