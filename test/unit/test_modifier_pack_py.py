#!/usr/bin/env python3
"""
Unit tests for the DSMP/DSMQ encoder, the modifier geometry, and the linker.

Pure stdlib + numpy (via healpix_utils); no QGIS, so this runs anywhere:

    python3 test/unit/test_modifier_pack_py.py

The GDScript side is covered by test/unit/test_modifier_pack.gd. The two meet in
test_canonical_tile_matches_gdscript below: both build the same tile and assert
the same SHA-256, so neither encoder can drift without the other noticing.
"""
import hashlib
import math
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "planettech", "qgis"))

from export.planet import dsmp                                    # noqa: E402
from export.planet import modifier_geom as mg                     # noqa: E402
from export.planet import roads as roads_mod                      # noqa: E402
from export.planet import biomes as biomes_mod                    # noqa: E402
from export.planet.dsmp_strings import StringTable                # noqa: E402
import link_modifiers                                             # noqa: E402

RADIUS = 6356000.0
MPD = mg.m_per_deg(RADIUS)

#: SHA-256 of the canonical tile payload. test/unit/test_modifier_pack.gd
#: asserts this exact constant from its own independent encoder, so the Python
#: writer and the GDScript reference writer cannot drift apart silently.
#: Changing the record layout means changing it here AND there, deliberately.
CANONICAL_TILE_SHA256 = \
    "40cbdc6f494f4d00f2f21ed46feca2329315ef7d4d3dd125e344618565635de7"


# ── The canonical tile, byte-identical on both sides ────────────────────

def canonical_tile():
    """One record of each kind, with fixed values. No nside/ipix dependence."""
    crater = dsmp.pack_crater(-39.4109184, 24.7707499, 1234.5, 98.75)
    linear = dsmp.pack_linear(
        type_sid=0, profile_sid=1, width_start_m=40.0, width_end_m=90.0,
        half_width_max_deg=0.0004, total_length_m=1500.0, feature_id=42,
        points=[(-1.0, 2.0, 400.0), (-0.99, 2.01, 700.0), (-0.98, 2.02, 1000.0)],
        depth_override=7.5)
    radial = dsmp.pack_radial(10.5, -20.25, 50.0, 12.5, 2, 3)
    populate = dsmp.pack_populate(
        biome_type_sid=7, biome_index=3, coverage="partial",
        props=[(8, dsmp.VTYPE_F32, 0.75), (9, dsmp.VTYPE_SID, 10)],
        vertices=[(5.0, 6.0), (5.1, 6.0), (5.1, 6.1), (5.0, 6.1)])
    road = dsmp.pack_road(
        road_type_sid=4, surface_sid=5, name_sid=6, lanes=2, width_m=6.0,
        total_length_m=2400.0, feature_id=1042,
        points=[(3.0, 4.0, 800.0), (3.005, 4.0, 1100.0)])
    return dsmp.build_tile({
        dsmp.KIND_CRATER: (1, crater),
        dsmp.KIND_LINEAR: (1, linear),
        dsmp.KIND_RADIAL: (1, radial),
        dsmp.KIND_POPULATE: (1, populate),
        dsmp.KIND_ROAD: (1, road),
    })


def _canonical_sha():
    return hashlib.sha256(canonical_tile()).hexdigest()


# ── Record encoding ─────────────────────────────────────────────────────

class TestRecordEncoding(unittest.TestCase):

    def test_e7_precision_is_about_one_centimetre(self):
        lon = -179.9999999
        err_deg = abs(dsmp.e7(lon) * dsmp.COORD_SCALE - lon)
        self.assertLess(err_deg * MPD, 0.02, "round-trip under 2 cm")

    def test_e7_rounds_half_away_from_zero(self):
        # Python's round() is banker's rounding and would return 0 here, which
        # would disagree with GDScript's round() and break byte-identity.
        self.assertEqual(dsmp.e7(0.00000005), 1)
        self.assertEqual(dsmp.e7(-0.00000005), -1)

    def test_e7_rejects_out_of_range(self):
        with self.assertRaises(dsmp.DsmpError):
            dsmp.e7(400.0)

    def test_crater_and_radial_are_fixed_size(self):
        self.assertEqual(len(dsmp.pack_crater(1, 2, 3, 4)), dsmp.CRATER_SIZE)
        self.assertEqual(len(dsmp.pack_radial(1, 2, 3, 4, 0, 0)), dsmp.RADIAL_SIZE)

    def test_linear_depth_override_flag(self):
        without = dsmp.pack_linear(0, 0, 1, 1, 0.1, 10, 0,
                                   [(0, 0, 0), (1, 1, 10)])
        with_ = dsmp.pack_linear(0, 0, 1, 1, 0.1, 10, 0,
                                 [(0, 0, 0), (1, 1, 10)], depth_override=3.0)
        self.assertEqual(len(with_) - len(without), 4, "one extra f32")
        self.assertEqual(without[4], 0, "flags bit0 clear")
        self.assertEqual(with_[4], 1, "flags bit0 set")

    def test_road_max_slope_tail(self):
        # Layout 2: 4-byte tail after point_count — flags bit0 + degrees.
        pts = [(1.0, 2.0, 0.0), (1.01, 2.0, 50.0)]
        plain = dsmp.pack_road(0, 1, 2, 2, 6.0, 50.0, 7, pts)
        graded = dsmp.pack_road(0, 1, 2, 2, 6.0, 50.0, 7, pts, max_slope_deg=6)
        self.assertEqual(len(plain), dsmp.ROAD_HEADER_SIZE[2] + 2 * dsmp.POINT_SIZE)
        self.assertEqual(struct.unpack_from("<BBH", plain, 24), (0, 0, 0))
        self.assertEqual(struct.unpack_from("<BBH", graded, 24),
                         (dsmp.ROAD_FLAG_MAX_SLOPE, 6, 0))
        # The points start right after the tail on both.
        self.assertEqual(plain[28:], graded[28:])
        with self.assertRaises(dsmp.DsmpError):
            dsmp.pack_road(0, 1, 2, 2, 6.0, 50.0, 7, pts, max_slope_deg=91)

    def test_road_lanes_unset_sentinel(self):
        r = dsmp.pack_road(0, 0, 0, None, 6.0, 10.0, 0, [(0, 0, 0), (1, 1, 10)])
        self.assertEqual(struct.unpack_from("<H", r, 6)[0], dsmp.SID_NONE)

    def test_populate_rejects_degenerate_partial(self):
        with self.assertRaises(dsmp.DsmpError):
            dsmp.pack_populate(0, 0, "partial", vertices=[(0, 0), (1, 1)])

    def test_populate_point_needs_lonlat(self):
        with self.assertRaises(dsmp.DsmpError):
            dsmp.pack_populate(0, 0, "point")

    def test_build_tile_orders_kinds_ascending(self):
        payload = canonical_tile()
        kind_count = struct.unpack_from("<H", payload, 2)[0]
        kinds = [struct.unpack_from("<BBHI", payload, 4 + i * 8)[0]
                 for i in range(kind_count)]
        self.assertEqual(kinds, sorted(kinds), "canonical kind order")
        self.assertEqual(kinds, [1, 2, 3, 4, 5])

    def test_build_tile_drops_empty_kinds(self):
        payload = dsmp.build_tile({
            dsmp.KIND_ROAD: (0, b""),
            dsmp.KIND_CRATER: (1, dsmp.pack_crater(0, 0, 1, 1)),
        })
        self.assertEqual(struct.unpack_from("<H", payload, 2)[0], 1)

    def test_split_pack_tile_round_trip(self):
        blocks = dsmp.split_pack_tile(canonical_tile())
        self.assertEqual(sorted(blocks), [1, 2, 3, 4, 5])
        self.assertEqual(blocks[dsmp.KIND_CRATER][0], 1)
        self.assertEqual(len(blocks[dsmp.KIND_CRATER][1]), dsmp.CRATER_SIZE)

    def test_canonical_tile_matches_gdscript(self):
        # If this fails, dsmp.py and test_modifier_pack.gd's reference writer
        # have drifted and the game will misread packs.
        self.assertEqual(_canonical_sha(), CANONICAL_TILE_SHA256)


# ── Container layout ────────────────────────────────────────────────────

class TestContainer(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="dsmp_test_")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _levels(self):
        tile = canonical_tile()
        return [(1, [(0, tile), (7, tile)]),
                (2, [(3, tile)]),
                (4, [(0, tile), (11, tile), (40, tile)])]

    def test_pack_round_trip(self):
        p = os.path.join(self.dir, "terrainmodifier.pack")
        dsmp.write_pack(p, self._levels(), {"strings": ["a", "b"], "x": 1})
        c = dsmp.read_container(p)
        self.assertEqual(c["magic"], dsmp.MAGIC_PACK)
        self.assertEqual(c["manifest"]["x"], 1)
        self.assertEqual([n for n, _t in c["levels"]], [1, 2, 4])
        self.assertEqual([ip for ip, _p in c["levels"][2][1]], [0, 11, 40])
        self.assertEqual(c["levels"][0][1][0][1], canonical_tile())

    def test_part_round_trip_carries_kind(self):
        p = os.path.join(self.dir, "roads.dsmpart")
        payload = dsmp.part_tile(1, dsmp.pack_crater(0, 0, 1, 1))
        dsmp.write_part(p, dsmp.KIND_ROAD, [(8, [(5, payload)])], {"kind": "road"})
        c = dsmp.read_container(p)
        self.assertEqual(c["magic"], dsmp.MAGIC_PART)
        self.assertEqual(c["kind"], dsmp.KIND_ROAD)
        count, records = dsmp.split_part_tile(c["levels"][0][1][0][1])
        self.assertEqual(count, 1)
        self.assertEqual(len(records), dsmp.CRATER_SIZE)

    def test_regions_are_16_byte_aligned(self):
        p = os.path.join(self.dir, "a.pack")
        dsmp.write_pack(p, self._levels(), {"strings": []})
        with open(p, "rb") as fh:
            head = fh.read(32)
        index_start, blob_start = struct.unpack_from("<II", head, 16)
        self.assertEqual(index_start % dsmp.ALIGN, 0)
        self.assertEqual(blob_start % dsmp.ALIGN, 0)

    def test_index_must_be_ascending(self):
        tile = canonical_tile()
        with self.assertRaises(dsmp.DsmpError):
            dsmp.write_pack(os.path.join(self.dir, "b.pack"),
                            [(1, [(7, tile), (3, tile)])], {})

    def test_write_is_atomic(self):
        p = os.path.join(self.dir, "c.pack")
        dsmp.write_pack(p, self._levels(), {})
        self.assertFalse(os.path.exists(p + ".tmp"), "no .tmp left behind")

    def test_rejects_bad_magic(self):
        p = os.path.join(self.dir, "bad.pack")
        dsmp.write_pack(p, self._levels(), {})
        with open(p, "r+b") as fh:
            fh.write(b"XXXX")
        with self.assertRaises(dsmp.DsmpError):
            dsmp.read_container(p)


# ── Geometry ────────────────────────────────────────────────────────────

class TestGeometry(unittest.TestCase):

    def test_douglas_peucker_pins_endpoints(self):
        pts = [(0.0, 0.0, 0.0), (0.5, 0.0001, 50.0), (1.0, 0.0, 100.0)]
        out = mg.douglas_peucker(pts, 1.0)
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0], pts[0])
        self.assertEqual(out[-1], pts[-1])

    def test_douglas_peucker_keeps_real_corners(self):
        pts = [(0.0, 0.0, 0.0), (0.5, 0.5, 50.0), (1.0, 0.0, 100.0)]
        self.assertEqual(len(mg.douglas_peucker(pts, 0.01)), 3)

    def test_douglas_peucker_carries_along_values(self):
        pts = [(0.0, 0.0, 400.0), (0.5, 0.0, 450.0), (1.0, 0.0, 500.0)]
        out = mg.douglas_peucker(pts, 1.0)
        self.assertAlmostEqual(out[0][2], 400.0)
        self.assertAlmostEqual(out[-1][2], 500.0, msg="parent distance preserved")

    def test_partition_is_exact_no_duplication(self):
        # THE invariant: the union of the per-tile pieces is the original road,
        # exactly once. Any duplication here is the two-roads bug coming back.
        pts = mg.with_cumulative(
            [(-39.7 + 0.02 * i, 24.6 + 0.01 * i) for i in range(150)], MPD)
        total = pts[-1][2]
        for nside in (64, 1024):
            parts = mg.partition_polyline(nside, pts)
            span = sum(pc[-1][2] - pc[0][2] for v in parts.values() for pc in v)
            self.assertAlmostEqual(
                span, total, delta=total * 1e-9,
                msg="n%d: piece spans must sum to the original" % nside)

    def test_partition_pieces_live_in_their_own_pixel(self):
        pts = mg.with_cumulative(
            [(-39.7 + 0.02 * i, 24.6 + 0.01 * i) for i in range(150)], MPD)
        nside = 64
        for ipix, pieces in mg.partition_polyline(nside, pts).items():
            for pc in pieces:
                for k in range(len(pc) - 1):
                    mlon = 0.5 * (pc[k][0] + pc[k + 1][0])
                    mlat = 0.5 * (pc[k][1] + pc[k + 1][1])
                    self.assertEqual(mg.pix_of(nside, mlon, mlat), ipix)

    def test_partition_neighbours_share_the_boundary_vertex(self):
        # A gap here would show up in game as a hole between two chunks' ribbons.
        pts = mg.with_cumulative(
            [(-39.7 + 0.05 * i, 24.6 + 0.02 * i) for i in range(80)], MPD)
        pieces = [pc for v in mg.partition_polyline(64, pts).values() for pc in v]
        pieces.sort(key=lambda pc: pc[0][2])
        for a, b in zip(pieces, pieces[1:]):
            self.assertEqual(a[-1], b[0],
                             "consecutive pieces must share an identical vertex")

    def test_partition_single_pixel_is_untouched(self):
        pts = mg.with_cumulative([(10.0, 20.0), (10.001, 20.001)], MPD)
        parts = mg.partition_polyline(64, pts)
        self.assertEqual(len(parts), 1)

    def test_clip_polyline_interpolates_along(self):
        pts = [(0.0, 0.0, 0.0), (10.0, 0.0, 1000.0)]
        pieces = mg.clip_polyline_to_bbox(pts, (2.0, 8.0, -1.0, 1.0))
        self.assertEqual(len(pieces), 1)
        self.assertAlmostEqual(pieces[0][0][2], 200.0, places=6)
        self.assertAlmostEqual(pieces[0][-1][2], 800.0, places=6)

    def test_clip_polyline_drops_disjoint(self):
        pts = [(0.0, 0.0, 0.0), (1.0, 0.0, 100.0)]
        self.assertEqual(mg.clip_polyline_to_bbox(pts, (5.0, 6.0, 5.0, 6.0)), [])

    def test_clip_polygon_to_bbox(self):
        ring = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
        out = mg.clip_polygon_to_bbox(ring, (2.0, 8.0, 2.0, 8.0))
        self.assertGreaterEqual(len(out), 4)
        for lon, lat in out:
            self.assertGreaterEqual(lon, 2.0 - 1e-9)
            self.assertLessEqual(lon, 8.0 + 1e-9)

    def test_level_policy_roads_reach_the_quadtree(self):
        pol = mg.level_policy(export_nside=64, max_quadtree_nside=8192)
        self.assertEqual(pol["road"]["max"], 8192)
        self.assertEqual(pol["linear"]["max"], 8192)
        self.assertEqual(pol["crater"]["max"], 64)
        self.assertEqual(pol["populate"]["max"], 64)

    def test_decim_eps_is_clamped_by_feature_width(self):
        # A 6 m road must not be decimated at a quarter of the 25 m vertex
        # spacing; the influence term has to win.
        eps = mg.decim_eps_m(8192, RADIUS, influence_r_m=3.0)
        self.assertAlmostEqual(eps, 1.5, places=6)

    def test_tiles_for_point_grows_with_influence(self):
        # Assignment only has to be a SUPERSET of the tiles a feature can
        # affect — an extra tile costs 16 bytes, a missing one loses the
        # displacement. Pruning is by tile bounding box, and the bboxes of
        # adjacent HEALPix pixels overlap, so a 1 m crater keeps its own tile
        # plus at most a neighbour or two rather than exactly one.
        home = mg.pix_of(64, 10.0, 20.0)
        small = mg.tiles_for_point(64, 10.0, 20.0, 1.0, RADIUS)
        big = mg.tiles_for_point(64, 10.0, 20.0, 300000.0, RADIUS)
        self.assertIn(home, small, "the containing tile is always assigned")
        self.assertIn(home, big)
        self.assertLessEqual(len(small), 3, "a 1 m influence stays local")
        self.assertGreater(len(big), len(small), "a 300 km influence spreads")

    def test_tiles_for_point_covers_the_influence_disc(self):
        # The property that actually matters: no tile within the influence
        # radius may be missing.
        lon, lat, influence = 10.0, 20.0, 250000.0
        got = mg.tiles_for_point(64, lon, lat, influence, RADIUS)
        mpd = mg.m_per_deg(RADIUS)
        step = influence / mpd / 8.0
        for i in range(-8, 9):
            for j in range(-8, 9):
                plon = lon + i * step / math.cos(math.radians(lat))
                plat = lat + j * step
                if math.hypot(i, j) * (influence / 8.0) > influence:
                    continue
                self.assertIn(mg.pix_of(64, plon, plat), got,
                              "tile at offset (%d, %d) must be covered" % (i, j))


# ── String table ────────────────────────────────────────────────────────

class TestStringTable(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="dsmp_str_")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_intern_is_stable(self):
        t = StringTable()
        a = t.intern("road")
        self.assertEqual(t.intern("road"), a)
        self.assertNotEqual(t.intern("path"), a)

    def test_empty_and_none_are_sid_none(self):
        t = StringTable()
        self.assertEqual(t.intern(None), dsmp.SID_NONE)
        self.assertEqual(t.intern(""), dsmp.SID_NONE)

    def test_save_load_round_trip(self):
        t = StringTable()
        t.intern("a")
        t.intern("b")
        t.save(self.dir)
        t2 = StringTable.load(self.dir)
        self.assertEqual(t2.as_list(), ["a", "b"])
        self.assertEqual(t2.intern("a"), 0)

    def test_append_only_across_exports(self):
        # Export A, then export B: A's ids must not move, or every record A
        # already wrote to disk would decode to the wrong string.
        t = StringTable()
        t.intern("road")
        t.intern("asphalt")
        t.save(self.dir)
        before = StringTable.load(self.dir)

        t2 = StringTable.load(self.dir)
        t2.intern("crater")
        t2.assert_extends(before)
        t2.save(self.dir)

        after = StringTable.load(self.dir)
        self.assertEqual(after.intern("road"), 0)
        self.assertEqual(after.intern("asphalt"), 1)
        self.assertEqual(after.intern("crater"), 2)

    def test_assert_extends_catches_reordering(self):
        older = StringTable(["a", "b"])
        with self.assertRaises(ValueError):
            StringTable(["b", "a"]).assert_extends(older)
        with self.assertRaises(ValueError):
            StringTable(["a"]).assert_extends(older)


# ── Road part builder ───────────────────────────────────────────────────

class TestRoadPart(unittest.TestCase):

    def test_half_width_matches_gdscript_rules(self):
        self.assertEqual(roads_mod.half_width_m({"width": 6.0}), 3.0)
        self.assertEqual(roads_mod.half_width_m({"road_type": "highway"}), 6.0)
        self.assertEqual(roads_mod.half_width_m({}), 0.5, "defaults to trail")
        self.assertEqual(roads_mod.half_width_m({"width": 0}), 0.5)

    def test_railway_half_width_follows_tracks(self):
        # One track = a 2.44 m sleeper + 0.5 m shoulders; two tracks add a 1 m gap.
        self.assertAlmostEqual(roads_mod.railway_half_width_m(1), 1.72)
        self.assertAlmostEqual(roads_mod.railway_half_width_m(2), 3.44)
        self.assertAlmostEqual(roads_mod.railway_half_width_m("2"), 3.44)
        self.assertEqual(roads_mod.railway_half_width_m(None), 2.5)
        self.assertEqual(roads_mod.railway_half_width_m(0), 2.5)
        # A railway has no `width`: `tracks` decides.  A stray `width` (legacy
        # single-table planet) is ignored, and `lanes` — where the track count
        # lived on that table — still counts when `tracks` is absent.
        self.assertAlmostEqual(
            roads_mod.half_width_m({"road_type": "railway", "tracks": 2}), 3.44)
        self.assertAlmostEqual(
            roads_mod.half_width_m({"road_type": "railway", "width": 5.0, "lanes": 2}),
            3.44)
        self.assertAlmostEqual(
            roads_mod.half_width_m({"road_type": "railway", "tracks": 1, "lanes": 2}),
            1.72)
        self.assertEqual(
            roads_mod.half_width_m({"road_type": "railway", "width": 5.0}), 2.5)

    def test_build_part_partitions_across_levels(self):
        table = StringTable()
        road = {
            "centerline": [(-39.7 + 0.01 * i, 24.6 + 0.005 * i) for i in range(200)],
            "road_type": "road", "width": 6.0, "lanes": 2,
            "surface": "asphalt", "name": "essai",
        }
        levels, manifest = roads_mod.build_road_part(
            [road], RADIUS, export_nside=64, max_quadtree_nside=1024,
            table=table, verbose=False)
        self.assertEqual(manifest["max_nside"], 1024)
        self.assertEqual([n for n, _t in levels], [1, 2, 4, 8, 16, 32, 64, 128,
                                                   256, 512, 1024])
        # Finer levels split the same road into strictly more tiles.
        counts = {n: len(t) for n, t in levels}
        self.assertGreater(counts[1024], counts[64])
        self.assertGreaterEqual(counts[64], 1)

    def test_build_part_stores_railway_tracks_in_lanes_slot(self):
        # The record layout has one u16 for lanes; a railway's `tracks` goes
        # there (no format change) and its surface is the unset sentinel.
        table = StringTable()
        railway = {
            "centerline": [(-39.7 + 0.01 * i, 24.6) for i in range(20)],
            "road_type": "railway", "tracks": 2, "name": "ligne 1",
        }
        levels, _manifest = roads_mod.build_road_part(
            [railway], RADIUS, export_nside=8, max_quadtree_nside=8,
            table=table, verbose=False)
        _n, tiles = levels[0]
        _count, rec = dsmp.split_part_tile(tiles[0][1])   # first record starts at 0
        self.assertEqual(table.as_list()[struct.unpack_from("<H", rec, 0)[0]], "railway")
        self.assertEqual(struct.unpack_from("<H", rec, 2)[0], dsmp.SID_NONE)   # surface
        self.assertEqual(struct.unpack_from("<H", rec, 6)[0], 2)               # tracks
        self.assertAlmostEqual(struct.unpack_from("<f", rec, 8)[0], 6.88, places=5)

    def test_build_part_marks_graded_roads(self):
        table = StringTable()
        cl = [(-39.7 + 0.01 * i, 24.6) for i in range(20)]
        roads = [
            {"centerline": cl, "road_type": "road", "width": 6.0, "max_slope_degrees": 6},
            {"centerline": cl, "road_type": "highway", "width": 12.0},
            # A trail's max_slope_degrees is ignored: only highway / road grade.
            {"centerline": cl, "road_type": "trail", "max_slope_degrees": 3},
        ]
        levels, manifest = roads_mod.build_road_part(
            roads, RADIUS, export_nside=8, max_quadtree_nside=8,
            table=table, verbose=False)
        self.assertEqual(manifest["record_layout"], 2)
        self.assertEqual(manifest["profiled_roads"], 1)
        _n, tiles = levels[0]
        _count, blob = dsmp.split_part_tile(tiles[0][1])
        flags = []
        p = 0
        while p < len(blob):
            npts = struct.unpack_from("<I", blob, p + 20)[0]
            flags.append(struct.unpack_from("<BB", blob, p + 24))
            p += dsmp.ROAD_HEADER_SIZE[2] + npts * dsmp.POINT_SIZE
        self.assertEqual(flags, [(1, 6), (0, 0), (0, 0)])

    def test_build_part_skips_degenerate_roads(self):
        table = StringTable()
        levels, manifest = roads_mod.build_road_part(
            [{"centerline": [(0.0, 0.0)]}], RADIUS, 64, 64, table, verbose=False)
        self.assertEqual(manifest["counts"]["features"], 0)
        self.assertTrue(all(len(t) == 0 for _n, t in levels))


# ── Populate part (biome regions) ───────────────────────────────────────

def _records_of(payload):
    """[(coverage, biome_index, props {key: value}, vertex_count), …] of a part tile."""
    _count, blob = dsmp.split_part_tile(payload)
    out = []
    p = 0
    while p < len(blob):
        _sid, cov, nprops, bidx, nverts, _rsv = struct.unpack_from("<HBBiHH", blob, p)
        p += 12
        props = {}
        for _ in range(nprops):
            key, vtype, _pad = struct.unpack_from("<HBB", blob, p)
            raw = blob[p + 4:p + 8]
            props[key] = (vtype, struct.unpack("<f", raw)[0] if vtype == dsmp.VTYPE_F32
                          else struct.unpack("<I", raw)[0] if vtype == dsmp.VTYPE_SID
                          else struct.unpack("<i", raw)[0])
            p += 8
        if cov == dsmp.COVERAGE_POINT:
            p += 8
        elif cov == dsmp.COVERAGE_PARTIAL:
            p += 8 * nverts
        out.append((cov, bidx, props, nverts))
    return out


class TestPopulatePart(unittest.TestCase):
    SQUARE = [(-45.0, 20.0), (-30.0, 20.0), (-30.0, 32.0), (-45.0, 32.0)]

    def test_bbox_inside_ring(self):
        ring = [(0, 0), (10, 0), (10, 10), (0, 10)]
        self.assertTrue(mg.bbox_inside_ring((1, 2, 1, 2), ring))
        self.assertFalse(mg.bbox_inside_ring((-1, 2, 1, 2), ring), "a corner outside")
        # A notch of the ring cutting through a box whose 4 corners are inside.
        notch = [(0, 0), (10, 0), (10, 10), (5, 10), (5, 3), (4, 3), (4, 10), (0, 10)]
        self.assertFalse(mg.bbox_inside_ring((3.5, 5.5, 2, 4), notch))
        self.assertTrue(mg.bbox_inside_ring((1, 3, 1, 2), notch))

    def test_full_and_partial_records_with_rock_props(self):
        table = StringTable()
        zone = {"ring": self.SQUARE, "biome_type": "outcrop-plateau", "biome_index": 105,
                "props": {"rock_type": "corundum_blue", "clarity": "milky",
                          "name": "Grand plateau", "density": 0.5, "fid": 7}}
        levels, manifest = biomes_mod.build_populate_part(
            [zone], 3467000.0, export_nside=64, max_quadtree_nside=64,
            table=table, verbose=False)
        self.assertEqual(manifest["kind"], "populate")
        self.assertEqual(manifest["max_nside"], 64)
        self.assertEqual(manifest["priority_rule"], "first-match")
        self.assertEqual(len(manifest["fingerprint"]), 40)
        nside, tiles = levels[-1]
        self.assertEqual(nside, 64)
        covs = {dsmp.COVERAGE_FULL: 0, dsmp.COVERAGE_PARTIAL: 0}
        strings = table.as_list()
        for _ipix, payload in tiles:
            for cov, bidx, props, nverts in _records_of(payload):
                covs[cov] += 1
                self.assertEqual(bidx, 105)
                named = {strings[k]: v for k, v in props.items()}
                self.assertEqual(strings[named["rock_type"][1]], "corundum_blue")
                self.assertEqual(strings[named["clarity"][1]], "milky")
                self.assertAlmostEqual(named["density"][1], 0.5, places=6)
                self.assertNotIn("fid", named, "housekeeping fields are not props")
                if cov == dsmp.COVERAGE_PARTIAL:
                    self.assertGreaterEqual(nverts, 3)
                else:
                    self.assertEqual(nverts, 0)
        self.assertGreater(covs[dsmp.COVERAGE_FULL], 0, "interior tiles are full")
        self.assertGreater(covs[dsmp.COVERAGE_PARTIAL], 0, "edge tiles are clipped")

    def test_overlapping_zones_are_ordered_by_priority_then_area(self):
        table = StringTable()
        big = self.SQUARE
        small = [(-38.0, 25.0), (-36.0, 25.0), (-36.0, 27.0), (-38.0, 27.0)]
        # Drawn big first with the HIGHER priority… the small one must still
        # come second; then swap priorities and the small one comes first.
        def order(p_big, p_small):
            levels, _m = biomes_mod.build_populate_part(
                [{"ring": big, "biome_type": "outcrop-plateau", "biome_index": 105,
                  "priority": p_big, "props": {}},
                 {"ring": small, "biome_type": "regolith-sand", "biome_index": 101,
                  "priority": p_small, "props": {}}],
                3467000.0, 64, 64, table, verbose=False)
            _n, tiles = levels[-1]
            for _ipix, payload in tiles:
                recs = _records_of(payload)
                if len(recs) == 2:
                    return [r[1] for r in recs]
            self.fail("no tile holds both zones")
        self.assertEqual(order(200, 100), [105, 101], "higher priority first")
        self.assertEqual(order(100, 200), [101, 105])
        self.assertEqual(order(0, 0), [101, 105], "equal priority: smaller area first")

    def test_deterministic_fingerprint(self):
        zone = {"ring": self.SQUARE, "biome_type": "x", "biome_index": 1, "props": {"a": 1}}
        _l1, m1 = biomes_mod.build_populate_part([zone], 3467000.0, 16, 16, StringTable(), verbose=False)
        _l2, m2 = biomes_mod.build_populate_part([zone], 3467000.0, 16, 16, StringTable(), verbose=False)
        self.assertEqual(m1["fingerprint"], m2["fingerprint"])
        zone2 = dict(zone, props={"a": 2})
        _l3, m3 = biomes_mod.build_populate_part([zone2], 3467000.0, 16, 16, StringTable(), verbose=False)
        self.assertNotEqual(m1["fingerprint"], m3["fingerprint"])


# ── Linker ──────────────────────────────────────────────────────────────

class TestLinker(unittest.TestCase):
    """The requirement in one class: exporting one kind must not touch another."""

    def setUp(self):
        self.export_dir = tempfile.mkdtemp(prefix="dsmp_link_")
        self.planet = "testplanet"
        self.chunks = link_modifiers.chunks_dir_for(self.planet, self.export_dir)
        self.parts = os.path.join(self.chunks, "parts")
        os.makedirs(self.parts, exist_ok=True)
        self.table = StringTable()

    def tearDown(self):
        shutil.rmtree(self.export_dir, ignore_errors=True)

    def _base_manifest(self, kind, max_nside=64):
        return {
            "kind": kind, "max_nside": max_nside, "min_nside": 1,
            "planet_name": self.planet, "radius": RADIUS,
            "export_nside": 64, "max_quadtree_nside": 64,
            "generated_by": "test",
        }

    def _write_roads(self, width=6.0):
        rec = dsmp.pack_road(
            self.table.intern("road"), self.table.intern("asphalt"),
            self.table.intern("route"), 2, width, 100.0, 1,
            [(1.0, 2.0, 0.0), (1.01, 2.0, 50.0)])
        levels = [(64, [(5, dsmp.part_tile(1, rec))])]
        dsmp.write_part(link_modifiers.part_path(self.planet, "road", self.export_dir),
                        dsmp.KIND_ROAD, levels, self._base_manifest("road"))
        self.table.save(self.parts)

    def _write_craters(self, radius_m=500.0):
        rec = dsmp.pack_crater(1.0, 2.0, radius_m, 40.0)
        levels = [(64, [(5, dsmp.part_tile(1, rec)), (9, dsmp.part_tile(1, rec))])]
        dsmp.write_part(link_modifiers.part_path(self.planet, "crater", self.export_dir),
                        dsmp.KIND_CRATER, levels, self._base_manifest("crater"))
        self.table.save(self.parts)

    def _read_pack(self):
        return dsmp.read_container(
            os.path.join(self.chunks, "terrainmodifier.pack"))

    def _blocks_at(self, pack, nside, ipix):
        for ns, tiles in pack["levels"]:
            if ns != nside:
                continue
            for ip, payload in tiles:
                if ip == ipix:
                    return dsmp.split_pack_tile(payload)
        return {}

    def test_link_merges_kinds_into_one_tile(self):
        self._write_roads()
        self._write_craters()
        link_modifiers.link(self.planet, self.export_dir, verbose=False)
        blocks = self._blocks_at(self._read_pack(), 64, 5)
        self.assertIn(dsmp.KIND_ROAD, blocks)
        self.assertIn(dsmp.KIND_CRATER, blocks)
        # Tile 9 only has craters.
        self.assertEqual(sorted(self._blocks_at(self._read_pack(), 64, 9)),
                         [dsmp.KIND_CRATER])

    def test_relink_replaces_only_its_own_kind(self):
        # The core requirement: re-export roads, craters must come out
        # bit-identical.
        self._write_roads(width=6.0)
        self._write_craters()
        link_modifiers.link(self.planet, self.export_dir, verbose=False)
        before = self._blocks_at(self._read_pack(), 64, 5)

        self._write_roads(width=12.0)
        link_modifiers.link(self.planet, self.export_dir, verbose=False)
        after = self._blocks_at(self._read_pack(), 64, 5)

        self.assertEqual(before[dsmp.KIND_CRATER], after[dsmp.KIND_CRATER],
                         "craters untouched by a roads re-export")
        self.assertNotEqual(before[dsmp.KIND_ROAD], after[dsmp.KIND_ROAD],
                            "roads did change")

    def test_link_is_idempotent(self):
        self._write_roads()
        self._write_craters()
        p = link_modifiers.link(self.planet, self.export_dir, verbose=False)
        first = hashlib.sha256(open(p, "rb").read()).hexdigest()
        link_modifiers.link(self.planet, self.export_dir, verbose=False)
        second = hashlib.sha256(open(p, "rb").read()).hexdigest()
        self.assertEqual(first, second, "unchanged parts → identical pack")

    def test_explode_round_trip(self):
        self._write_roads()
        self._write_craters()
        p = link_modifiers.link(self.planet, self.export_dir, verbose=False)
        before = hashlib.sha256(open(p, "rb").read()).hexdigest()

        for f in os.listdir(self.parts):
            os.remove(os.path.join(self.parts, f))
        link_modifiers.explode(self.planet, self.export_dir, verbose=False)
        link_modifiers.link(self.planet, self.export_dir, verbose=False)
        after = hashlib.sha256(open(p, "rb").read()).hexdigest()
        self.assertEqual(before, after, "link(explode(pack)) == pack")

    def test_link_rejects_shallow_road_level(self):
        # A road baked shallower than the quadtree would make deep chunks share
        # an ancestor tile — the doubling bug.
        rec = dsmp.pack_road(0, 0, 0, None, 6.0, 100.0, 1,
                             [(1.0, 2.0, 0.0), (1.01, 2.0, 50.0)])
        m = self._base_manifest("road", max_nside=64)
        m["max_quadtree_nside"] = 8192
        dsmp.write_part(link_modifiers.part_path(self.planet, "road", self.export_dir),
                        dsmp.KIND_ROAD, [(64, [(5, dsmp.part_tile(1, rec))])], m)
        self.table.save(self.parts)
        with self.assertRaises(dsmp.DsmpError) as ctx:
            link_modifiers.link(self.planet, self.export_dir, verbose=False)
        self.assertIn("render the road twice", str(ctx.exception))

    def test_link_rejects_disagreeing_parts(self):
        self._write_roads()
        m = self._base_manifest("crater")
        m["radius"] = 1234.0          # stale part from another planet geometry
        rec = dsmp.pack_crater(1.0, 2.0, 10.0, 1.0)
        dsmp.write_part(link_modifiers.part_path(self.planet, "crater", self.export_dir),
                        dsmp.KIND_CRATER, [(64, [(5, dsmp.part_tile(1, rec))])], m)
        with self.assertRaises(dsmp.DsmpError):
            link_modifiers.link(self.planet, self.export_dir, verbose=False)

    def test_link_without_parts_fails_clearly(self):
        with self.assertRaises(dsmp.DsmpError):
            link_modifiers.link(self.planet, self.export_dir, verbose=False)

    def test_manifest_records_part_provenance(self):
        self._write_roads()
        self._write_craters()
        link_modifiers.link(self.planet, self.export_dir, verbose=False)
        m = self._read_pack()["manifest"]
        self.assertEqual(sorted(m["parts"]), ["crater", "road"])
        self.assertEqual(m["kind_max_nside"]["road"], 64)
        self.assertEqual(m["strings"], self.table.as_list())


if __name__ == "__main__":
    print("canonical tile SHA-256: %s" % CANONICAL_TILE_SHA256)
    unittest.main(verbosity=2)
