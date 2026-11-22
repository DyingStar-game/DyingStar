"""Unit tests of modifier_geom.tiles_for_polygon: the interior of a big polygon is no longer lost.

    python -m unittest tools/planettech/qgis/export/planet/test_tiles_for_polygon.py

No QGIS, no healpy needed (healpix_utils falls back to pure Python). Until 2026-11 the interior of a
polygon was sampled on a lon/lat grid only below 4 million grid points; above that only the boundary
tiles came back, so planet-wide biome zones were missing from their interior at n256 and finer.
_old_tiles_for_polygon below is that code verbatim, kept as the reference the new one must match
under the cap and beat above it.
"""

import math
import os
import random
import sys
import unittest

_QGIS_DIR = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, _QGIS_DIR)

from export.planet import modifier_geom as mg  # noqa: E402
import healpix_utils as hpx  # noqa: E402

RADIUS = 6356000.0


def _vec2pix_nest_godot(nside, x, y, z):
    """scenes/planet/healpix.gd vec2pix_nest_from_zphi, line for line (y-up).

    healpix_utils' pure-Python fallback still computes the equatorial face column as
    (jp + nside) // (2 * nside), the bug healpix.gd fixed (it maps faces 6->5, 7->6): it disagrees
    with Godot and healpy on ~1/3 of the sphere, so it is not even consistent with healpix_utils'
    own pix2vec. The exports are made with healpy; without it these tests use this port instead.
    """
    za = abs(y)
    phi = math.atan2(-z, x)
    if phi < 0:
        phi += 2.0 * math.pi
    tt = phi / (math.pi * 0.5)
    while tt < 0.0:
        tt += 4.0
    while tt >= 4.0:
        tt -= 4.0
    if za <= 2.0 / 3.0:
        temp1 = nside * (0.5 + tt)
        temp2 = nside * y * 0.75
        jp = int(temp1 - temp2)
        jm = int(temp1 + temp2)
        ifp = jp // nside
        ifm = jm // nside
        face = (ifp | 4) if ifp == ifm else (ifp if ifp < ifm else ifm + 8)
        ix = jm & (nside - 1)
        iy = nside - (jp & (nside - 1)) - 1
    else:
        tp = tt - math.floor(tt)
        tmp = nside * math.sqrt(3.0 * (1.0 - za))
        jp = min(int(tp * tmp), nside - 1)
        jm = min(int((1.0 - tp) * tmp), nside - 1)
        if y > 0:
            face = min(int(tt), 3)
            ix = nside - jm - 1
            iy = nside - jp - 1
        else:
            face = min(int(tt) + 8, 11)
            ix = jp
            iy = jm
    return face * nside * nside + hpx.xy2nest(ix, iy)


if not hpx.HAS_HEALPY:
    hpx.vec2pix_nest = _vec2pix_nest_godot   # also used by get_neighbor_pixels' fallback


def _old_tiles_for_polygon(nside, ring, influence_m, radius_m):
    """modifier_geom.tiles_for_polygon as shipped before the fix (capped interior grid)."""
    step = 0.5 * mg.pixel_side_deg(nside)
    closed = list(ring) + [ring[0]]
    seeds = {mg.pix_of(nside, p[0], p[1]) for p in mg._densify(closed, step)}
    lons = [p[0] for p in ring]
    lats = [p[1] for p in ring]
    lon0, lon1 = min(lons), max(lons)
    lat0, lat1 = min(lats), max(lats)
    ny = max(int(math.ceil((lat1 - lat0) / step)), 1)
    nx = max(int(math.ceil((lon1 - lon0) / step)), 1)
    if nx * ny <= 4_000_000:
        for iy in range(ny + 1):
            lat = lat0 + (lat1 - lat0) * iy / ny
            for ix in range(nx + 1):
                lon = lon0 + (lon1 - lon0) * ix / nx
                if mg.point_in_ring(lon, lat, ring):
                    seeds.add(mg.pix_of(nside, lon, lat))
    return mg.dilate(nside, seeds, mg._rings_for(nside, radius_m, influence_m))


def _brute_force(nside, ring, influence_m=0.0, radius_m=RADIUS):
    """The definition, tile by tile over the whole sphere: boundary seeds U tiles with a sample inside."""
    seeds = mg._boundary_pixels(nside, ring, 0.5) | mg._boundary_pixels_refined(nside, ring)
    every = range(12 * nside * nside)
    tiles = seeds | mg._any_sample_inside(nside, every, ring, mg.POLY_SAMPLES)
    return mg.dilate(nside, tiles, mg._rings_for(nside, radius_m, influence_m))


def _blob(cx, cy, rx, ry, n, seed):
    """A concave, star-shaped ring around (cx, cy)."""
    rnd = random.Random(seed)
    ring = []
    for i in range(n):
        a = 2.0 * math.pi * i / n
        k = 0.55 + 0.45 * rnd.random()
        ring.append((cx + rx * k * math.cos(a), cy + ry * k * math.sin(a)))
    return ring


#: A planet-wide zone: a belt over every longitude, notched so it is not a plain box.
PLANET_BELT = [(-179.0, -80.0), (179.0, -80.0), (179.0, 80.0), (20.0, 80.0), (20.0, 40.0),
               (-20.0, 40.0), (-20.0, 80.0), (-179.0, 80.0)]

#: Small and medium polygons, all well under the old cap at the levels they are tested at.
SMALL = {
    "square": [(10.0, 10.0), (20.0, 10.0), (20.0, 18.0), (10.0, 18.0)],
    "concave_blob": _blob(-40.0, 25.0, 15.0, 10.0, 40, 1),
    "north_cap_blob": _blob(60.0, 72.0, 25.0, 10.0, 30, 2),
    "south_belt_edge": _blob(120.0, -50.0, 30.0, 12.0, 25, 3),
    "antimeridian_edge": [(170.0, -10.0), (180.0, -10.0), (180.0, 10.0), (170.0, 10.0)],
    "north_pole_cap": [(-180.0, 70.0), (180.0, 70.0), (180.0, 90.0), (-180.0, 90.0)],
    "thin_sliver": [(0.0, 0.0), (30.0, 0.5), (30.0, 0.8), (0.0, 0.3)],
}


class InteriorAboveTheCapTest(unittest.TestCase):
    """(a) A polygon whose old interior grid exceeds 4 million points."""

    NSIDE = 256

    def test_old_grid_really_exceeds_the_cap(self):
        step = 0.5 * mg.pixel_side_deg(self.NSIDE)
        nx = math.ceil(358.0 / step)
        ny = math.ceil(160.0 / step)
        self.assertGreater(nx * ny, 4_000_000)

    def test_interior_tile_is_present(self):
        centre = mg.pix_of(self.NSIDE, -100.0, 0.0)
        got = mg.tiles_for_polygon(self.NSIDE, PLANET_BELT, 0.0, RADIUS)
        old = _old_tiles_for_polygon(self.NSIDE, PLANET_BELT, 0.0, RADIUS)
        self.assertIn(centre, got)
        # The bug being fixed: the old code returns the boundary only.
        self.assertNotIn(centre, old)
        self.assertLess(len(old), 0.1 * len(got))

    def test_matches_brute_force_on_the_whole_sphere(self):
        got = mg.tiles_for_polygon(self.NSIDE, PLANET_BELT, 0.0, RADIUS)
        self.assertEqual(got, _brute_force(self.NSIDE, PLANET_BELT))
        # Sanity: the belt covers ~sin(80 deg) minus the notch, ~96 % of the sphere.
        self.assertGreater(len(got), 0.9 * 12 * self.NSIDE ** 2)


class BruteForceTest(unittest.TestCase):
    """(b) The descent equals the tile-by-tile definition."""

    def test_small_cases(self):
        for nside in (1, 2, 8, 32, 64):
            for name, ring in SMALL.items():
                with self.subTest(nside=nside, ring=name):
                    self.assertEqual(mg.tiles_for_polygon(nside, ring, 0.0, RADIUS),
                                     _brute_force(nside, ring))

    def test_with_influence(self):
        # Mountains / rocky terrain pass a margin: the frontier-only dilation must equal dilating all.
        for nside, margin in ((16, 300_000.0), (64, 150_000.0)):
            for name in ("concave_blob", "north_pole_cap", "antimeridian_edge"):
                ring = SMALL[name]
                with self.subTest(nside=nside, ring=name):
                    self.assertEqual(mg.tiles_for_polygon(nside, ring, margin, RADIUS),
                                     _brute_force(nside, ring, margin))

    def test_planet_belt_with_influence(self):
        self.assertEqual(mg.tiles_for_polygon(32, PLANET_BELT, 400_000.0, RADIUS),
                         _brute_force(32, PLANET_BELT, 400_000.0))

    def test_vectorised_point_in_ring_is_the_scalar_one(self):
        rnd = random.Random(7)
        ring = SMALL["concave_blob"]
        lons = [rnd.uniform(-60.0, -20.0) for _ in range(3000)] + [p[0] for p in ring]
        lats = [rnd.uniform(10.0, 40.0) for _ in range(3000)] + [p[1] for p in ring]
        vec = mg.points_in_ring(lons, lats, ring)
        self.assertEqual(list(vec), [mg.point_in_ring(lo, la, ring) for lo, la in zip(lons, lats)])


class SameAsBeforeUnderTheCapTest(unittest.TestCase):
    """(c) Under the cap nothing the old code returned is lost. The only additions are tiles an edge
    clips at a corner, which the old half-pixel grid stepped over: at most 1 % more tiles, and every
    one of them really touched by the ring (a boundary sample every 1/20 pixel lands in it, or one of
    12 x 12 samples is inside)."""

    CASES = [
        (64, "square"), (128, "square"), (64, "concave_blob"), (128, "concave_blob"),
        (64, "north_cap_blob"), (64, "south_belt_edge"), (64, "antimeridian_edge"),
        (32, "north_pole_cap"), (128, "thin_sliver"),
    ]
    _rnd = random.Random(5)
    for _i in range(40):
        CASES.append((_rnd.choice([32, 64, 128, 256]),
                      _blob(_rnd.uniform(-160.0, 160.0), _rnd.uniform(-75.0, 75.0),
                            _rnd.uniform(1.0, 20.0), _rnd.uniform(1.0, 12.0), _rnd.randint(8, 80), _i)))

    @staticmethod
    def _edge_touches(nside, ring, tiles):
        """Tiles of [tiles] containing a point of the ring's edges, sampled every 1/50000 pixel.

        Independent of the bisection in modifier_geom: each edge is clipped to the tile's padded
        lon/lat box and that piece is walked at a fixed, very fine step.
        """
        out = set()
        step = 0.00002 * mg.pixel_side_deg(nside)
        closed = list(ring) + [ring[0]]
        for t in tiles:
            box = mg.tile_bbox(nside, t, 0.5 * mg.pixel_side_deg(nside))
            for a, b in zip(closed, closed[1:]):
                piece = mg._clip_segment(a, b, box)
                if piece and any(mg.pix_of(nside, p[0], p[1]) == t
                                 for p in mg._densify(piece, step)):
                    out.add(t)
                    break
        return out

    def test_old_tiles_kept_additions_real(self):
        total_old = total_gained = 0
        for nside, ring in self.CASES:
            ring = SMALL[ring] if isinstance(ring, str) else ring
            with self.subTest(nside=nside, ring=ring[:2]):
                old = _old_tiles_for_polygon(nside, ring, 0.0, RADIUS)
                new = mg.tiles_for_polygon(nside, ring, 0.0, RADIUS)
                self.assertEqual(old - new, set())
                gained = new - old
                touched = mg._any_sample_inside(nside, gained, ring, 12)
                touched |= self._edge_touches(nside, ring, gained - touched)
                self.assertEqual(gained - touched, set())
                total_old += len(old)
                total_gained += len(gained)
        # Corner clips only: a few percent of a small polygon's tiles, nothing like a second ring.
        self.assertLess(total_gained, 0.03 * total_old)


if __name__ == "__main__":
    unittest.main()
