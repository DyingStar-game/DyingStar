"""Binding a garment and putting it back on a body.

On a synthetic body (a closed tube, always there) and, when build/character/human_bank.npz exists, on the game's.

usage: python3 -m unittest discover tools/character/garments
"""
import os
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import garment_bind as gb  # noqa: E402

BANK = os.path.join(HERE, "..", "..", "..", "build", "character", "human_bank.npz")


def tube(radius, height, rings=24, sides=32):
    """A capped cylinder along Y, counter-clockwise from outside: (points, tris)."""
    pts = []
    for r in range(rings + 1):
        y = height * r / rings
        for s in range(sides):
            a = 2.0 * np.pi * s / sides
            pts.append((radius * np.cos(a), y, radius * np.sin(a)))
    tris = []
    for r in range(rings):
        for s in range(sides):
            a, b = r * sides + s, r * sides + (s + 1) % sides
            c, d = a + sides, b + sides
            tris += [(a, c, b), (b, c, d)]
    bottom, top = len(pts), len(pts) + 1
    pts += [(0.0, 0.0, 0.0), (0.0, height, 0.0)]
    for s in range(sides):
        a, b = s, (s + 1) % sides
        tris.append((bottom, a, b))
        tris.append((top, rings * sides + b, rings * sides + a))
    return np.array(pts), np.array(tris)


def body_of(points, tris):
    n = len(points)
    bones = np.zeros((n, 4), dtype=np.uint8)
    bones[:, 0] = (points[:, 1] > points[:, 1].mean()).astype(np.uint8)  # bone 0 below, bone 1 above
    weights = np.zeros((n, 4))
    weights[:, 0] = 1.0
    return gb.Body(points, tris, np.ones(n, dtype=bool), bones, weights, 2)


def sleeve(radius, y0, y1, rings=10, sides=40):
    """An open tube (no caps) from y0 to y1, with a UV seam: (points, tris, corner_uv)."""
    pts, uvs = [], []
    for r in range(rings + 1):
        y = y0 + (y1 - y0) * r / rings
        for s in range(sides):
            a = 2.0 * np.pi * s / sides
            pts.append((radius * np.cos(a), y, radius * np.sin(a)))
    tris, cuv = [], []
    for r in range(rings):
        for s in range(sides):
            a, b = r * sides + s, r * sides + (s + 1) % sides
            c, d = a + sides, b + sides
            u0, u1 = s / sides, (s + 1) / sides
            v0, v1 = r / rings, (r + 1) / rings
            tris += [(a, c, b), (b, c, d)]
            cuv += [(u0, v0), (u0, v1), (u1, v0), (u1, v0), (u0, v1), (u1, v1)]
    return np.array(pts), np.array(tris), np.array(cuv)


class SyntheticBindTest(unittest.TestCase):
    def setUp(self):
        self.body_pts, self.body_tris = tube(0.10, 1.0)
        self.body = body_of(self.body_pts, self.body_tris)
        self.g_pts, self.g_tris, self.g_uv = sleeve(0.11, 0.30, 0.70)

    def test_back_on_the_same_body(self):
        arrays, report = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body)
        np.testing.assert_allclose(gb.fit(self.body.points, arrays), self.g_pts, atol=1e-6)
        self.assertEqual(report["poke_share"], 0.0)
        self.assertTrue(report["ok"])
        np.testing.assert_allclose(arrays["weights"].sum(1), 1.0, atol=1e-5)

    def test_follows_a_fatter_body(self):
        arrays, _r = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body)
        fat = self.body.points * np.array([1.3, 1.0, 1.3])
        on_fat = gb.fit(fat, arrays)
        radius = np.linalg.norm(on_fat[:, [0, 2]], axis=1)
        # the sleeve keeps its 1 cm over the skin (to the tube's facet error), not its old radius
        np.testing.assert_allclose(radius, 0.13 + 0.01, atol=0.0015)

    def test_hides_the_skin_under_it_only(self):
        arrays, report = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body)
        hidden = arrays["delete"]
        y = self.body.points[hidden, 1]
        self.assertGreater(len(hidden), 0)
        self.assertTrue((y > 0.30).all() and (y < 0.70).all(), "hidden skin stays under the sleeve")
        side = np.abs(np.linalg.norm(self.body.points[:, [0, 2]], axis=1) - 0.10) < 1e-6
        middle = side & (self.body.points[:, 1] > 0.40) & (self.body.points[:, 1] < 0.60)
        self.assertTrue(np.isin(np.nonzero(middle)[0], hidden).all(), "the skin well under the sleeve is hidden")
        self.assertEqual(report["hidden_skin"], len(hidden))

    def test_poke_is_reported(self):
        inside = sleeve(0.09, 0.30, 0.70)
        _a, report = gb.bind(inside[0], inside[1], inside[2], self.body)
        self.assertGreater(report["poke_share"], 0.9)
        self.assertFalse(report["ok"])

    def test_layer_clearance(self):
        _a, report = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body, layer=3)
        self.assertGreater(report["close_share"], 0.9, "1 cm is too close for a coat (1.5 cm)")
        _a, report = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body, layer=1)
        self.assertEqual(report["close_share"], 0.0)

    def test_render_mesh_splits_uv_seams(self):
        arrays, _r = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body)
        rings, sides = 11, 40
        self.assertEqual(len(arrays["vertex"]), rings * (sides + 1), "one extra column at the seam")
        self.assertEqual(len(arrays["index"]), len(self.g_tris) * 3)
        np.testing.assert_array_equal(arrays["vertex"][arrays["index"]], self.g_tris.reshape(-1))

    def test_bones_follow_the_skin(self):
        arrays, _r = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body)
        src_y = self.g_pts[arrays["vertex"], 1]
        low = src_y < 0.45
        self.assertTrue((arrays["bones"][low, 0] == 0).all())
        self.assertTrue((arrays["bones"][src_y > 0.55, 0] == 1).all())
        np.testing.assert_allclose(arrays["bone_weights"].sum(1), 1.0, atol=1e-5)

    def test_scale_pairs(self):
        top = int(np.argmax(self.body.points[:, 1]))
        bottom = int(np.argmin(self.body.points[:, 1]))
        pairs = np.array([[-1, -1], [bottom, top], [-1, -1]])
        arrays, _r = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body, scale_pairs=pairs)
        np.testing.assert_allclose(gb.fit(self.body.points, arrays), self.g_pts, atol=1e-6)

    def test_file_round_trip(self):
        arrays, _r = gb.bind(self.g_pts, self.g_tris, self.g_uv, self.body)
        meta = {"id": "test_sleeve", "zones": ["4G"], "support": 0, "layer": 1, "access": 1}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "test_sleeve.dsgarment")
            gb.write_garment(path, arrays, meta)
            self.assertTrue(os.path.exists(path))
            back, back_meta = gb.read_garment(path)
        self.assertEqual(back_meta["id"], "test_sleeve")
        self.assertEqual(back_meta["format"], gb.GARMENT_FORMAT)
        for k in gb.ARRAY_KEYS:
            np.testing.assert_array_equal(back[k], arrays[k])
            self.assertEqual(back[k].dtype, arrays[k].dtype, k)


GARMENT = os.path.join(HERE, "..", "..", "..", "assets", "_universe", "characters", "human", "garments",
                       "mh_male_casualsuit01", "mh_male_casualsuit01.dsgarment")


@unittest.skipUnless(os.path.exists(BANK), "build/character/human_bank.npz not built")
class BankBindTest(unittest.TestCase):
    """The game's body: a garment of the project (a MakeHuman suit), bound again from its own fitted positions."""

    @classmethod
    def setUpClass(cls):
        cls.bank = dict(np.load(BANK, allow_pickle=False))

    def test_rebind_a_garment(self):
        old, meta = gb.read_garment(GARMENT)
        body = gb.Body.from_bank(self.bank, {"Gender_Male" if meta["bound_on"] == "male" else "Gender_Female": 1.0})
        self.assertEqual(meta["body_signature"], body.signature, "the garment was bound to this bank's body")
        points = gb.fit(body.points, old)
        tris = old["vertex"][old["index"]].reshape(-1, 3)
        uv = old["uv"][old["index"]].astype(np.float64)
        uv[:, 1] = 1.0 - uv[:, 1]
        arrays, report = gb.bind(points, tris, uv, body)
        np.testing.assert_allclose(gb.fit(body.points, arrays), points, atol=1e-5)
        neutral = gb.morph(self.bank, {})
        np.testing.assert_allclose(gb.fit(neutral, arrays), gb.fit(neutral, old), atol=0.01,
                                   err_msg="bound alike, the garment sits alike on another body (1 cm)")
        self.assertLess(report["poke_share"], gb.MAX_POKE_SHARE)
        self.assertGreater(len(arrays["delete"]), 0.5 * len(old["delete"]))

    def test_signature_is_stable(self):
        tris = gb.bank_triangles(self.bank)
        a = gb.body_signature(self.bank["base"], tris)
        self.assertEqual(a, gb.body_signature(self.bank["base"].copy(), tris.copy()))
        moved = self.bank["base"].copy()
        moved[0, 0] += 1e-3
        self.assertNotEqual(a, gb.body_signature(moved, tris))


if __name__ == "__main__":
    unittest.main()
