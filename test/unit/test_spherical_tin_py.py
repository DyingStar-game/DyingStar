#!/usr/bin/env python3
"""Le TIN sphérique face à des contours qui ne couvrent qu'une calotte.

Une planète en cours d'édition n'a souvent que deux ou trois contours dans un coin
(tarsis_8 : un anneau à 30 m et un plateau à 300 m sur ~30 km). L'enveloppe convexe des
directions unitaires n'entoure alors PAS l'origine : c'est une lentille, dont le dessus
est bien la Delaunay de la calotte mais dont le DESSOUS est le contour extérieur
triangulé à plat, entièrement à 30 m. Les deux faces sont à distance ~1 de l'origine,
donc le KD-tree des centroïdes les mélange, et le test rayon/triangle (somme des poids
> 0) ne les distingue pas non plus. Résultat mesuré sur tarsis_8 : un plateau dessiné
plat à 300 m criblé de trous à 30 m, et des pics à 300 m sur la pente — les « bosses »
vues dans Godot.

Ce qui est couvert :
  1. L'intérieur d'un contour fermé est plat à sa cote, même sans couverture globale.
  2. Les faces du dessous sont bien retirées, et seulement elles.
  3. Un jeu de points qui entoure la sphère ne perd aucun triangle (non-régression).
  4. L'exactitude aux sommets et la borne par les entrées tiennent dans les deux cas.

Run:  python3 test/unit/test_spherical_tin_py.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                "tools", "planettech", "qgis"))

try:
    import numpy as np
    from scipy.spatial import ConvexHull
except ImportError:  # pragma: no cover
    print("SKIP test_spherical_tin_py: numpy/scipy absents")
    sys.exit(0)

from export.planet.spherical_tin import SphericalTIN

C_LON, C_LAT = -103.7, -23.85


def _ring(radius_deg, n, elev, wobble=0.0):
    """Anneau de sommets autour de (C_LON, C_LAT), légèrement lobé si wobble > 0."""
    t = np.linspace(0.0, 2.0 * np.pi, n, endpoint=False)
    r = radius_deg * (1.0 + wobble * np.cos(2.0 * t))
    lon = C_LON + r * np.cos(t) / np.cos(np.radians(C_LAT))
    lat = C_LAT + r * np.sin(t)
    return np.column_stack([lon, lat, np.full(n, float(elev))])


def _cap_points():
    return np.vstack([_ring(0.30, 200, 30.0, 0.15), _ring(0.15, 120, 300.0, 0.20)])


class CapOnlyContours(unittest.TestCase):
    def setUp(self):
        self.pts = _cap_points()
        self.tin = SphericalTIN(self.pts[:, 0], self.pts[:, 1], self.pts[:, 2],
                                verbose=False)

    def test_plateau_interior_is_flat_at_its_contour(self):
        # Un disque bien à l'intérieur de l'anneau à 300 m (rayon 0,15° lobé à ±20 %,
        # donc jamais sous 0,12°) : tout doit valoir exactement 300.
        t = np.linspace(0.0, 2.0 * np.pi, 64, endpoint=False)
        for r in (0.0, 0.03, 0.06, 0.09):
            lon = C_LON + r * np.cos(t) / np.cos(np.radians(C_LAT))
            lat = C_LAT + r * np.sin(t)
            v = self.tin.sample_lonlat(lon, lat)
            self.assertTrue(np.allclose(v, 300.0, atol=1e-6),
                            f"r={r}: min {v.min():.1f}, max {v.max():.1f}")

    def test_underside_faces_are_dropped(self):
        hull = ConvexHull(self.tin.xyz)
        underside = int((hull.equations[:, 3] >= 0.0).sum())
        self.assertGreater(underside, 0, "le jeu de test doit être une calotte")
        self.assertEqual(self.tin.n_triangles, len(hull.simplices) - underside)

    def test_outside_the_cap_falls_back_to_the_nearest_sample(self):
        v = self.tin.sample_lonlat(np.array([C_LON + 60.0, C_LON - 120.0]),
                                   np.array([C_LAT + 40.0, -C_LAT]))
        self.assertTrue(np.allclose(v, 30.0))

    def test_bounded_and_exact_at_vertices(self):
        v = self.tin.sample_lonlat(self.pts[:, 0], self.pts[:, 1])
        self.assertLess(np.abs(v - self.pts[:, 2]).max(), 1e-6)
        lons = np.linspace(C_LON - 0.4, C_LON + 0.4, 80)
        lats = np.linspace(C_LAT + 0.4, C_LAT - 0.4, 60)
        g = self.tin.sample_lonlat(*np.meshgrid(lons, lats))
        self.assertGreaterEqual(g.min(), 30.0 - 1e-9)
        self.assertLessEqual(g.max(), 300.0 + 1e-9)


class WholeSphereContours(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(0)
        n = 3000
        self.lon = rng.uniform(-180.0, 180.0, n)
        self.lat = np.degrees(np.arcsin(rng.uniform(-1.0, 1.0, n)))
        self.val = rng.uniform(0.0, 1000.0, n)
        self.tin = SphericalTIN(self.lon, self.lat, self.val, verbose=False)

    def test_no_face_is_dropped_when_the_samples_enclose_the_sphere(self):
        hull = ConvexHull(self.tin.xyz)
        self.assertTrue(np.all(hull.equations[:, 3] < 0.0))
        self.assertEqual(self.tin.n_triangles, len(hull.simplices))

    def test_exact_at_vertices(self):
        v = self.tin.sample_lonlat(self.lon, self.lat)
        self.assertLess(np.abs(v - self.val).max(), 1e-6)


if __name__ == "__main__":
    unittest.main()
