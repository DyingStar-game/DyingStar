#!/usr/bin/env python3
"""Tests de tools/planettech/publish/publish_tiles.py — l'éclatement d'un pack en arborescence servable.

Ce que publie cet outil part chez les joueurs. Les défauts qu'il pourrait avoir ne lèvent
aucune erreur : un décalage de sharding ou une carte de présence inversée donne un terrain
faux, pas un plantage. D'où ces tests, et d'où le mode --verify de l'outil lui-même.

Run:  python3 test/unit/test_publish_tiles_py.py
"""

import json
import os
import re
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

try:
    import numpy as np
    from tools.planettech.publish import publish_tiles as PT
except ImportError as exc:  # pragma: no cover
    print("SKIP test_publish_tiles_py: %s" % exc)
    sys.exit(0)


TR = 4
LEVELS = [1, 2, 4]


def present(nside, ipix):
    return nside == 1 or (ipix + nside) % 3 != 0


def value(nside, ipix):
    return (nside * 37 + ipix * 11) % 65535


def write_pack(path, sparse=True):
    """Pack DSHP v2 minimal (uint16, éventuellement creux)."""
    manifest = json.dumps({"planet_name": "pubtest", "tile_res": TR,
                           "data_version": "cafe1234"}).encode()
    bitmap_bytes = sum((12 * n * n + 7) // 8 for n in LEVELS) if sparse else 0
    blob_start = 32 + len(manifest) + bitmap_bytes
    with open(path, "wb") as f:
        f.write(b"DSHP" + struct.pack("<7I", 2, TR, LEVELS[0], LEVELS[-1],
                                      1 | (2 if sparse else 0), blob_start, len(manifest)))
        f.write(manifest)
        if sparse:
            for n in LEVELS:
                npix = 12 * n * n
                bits = bytearray((npix + 7) // 8)
                for ip in range(npix):
                    if present(n, ip):
                        bits[ip >> 3] |= 1 << (ip & 7)
                f.write(bytes(bits))
        for n in LEVELS:
            for ip in range(12 * n * n):
                if sparse and not present(n, ip):
                    continue
                f.write(np.full(TR * TR, value(n, ip), dtype="<u2").tobytes())


class TileEnvelope(unittest.TestCase):

    def test_round_trip_uncompressed(self):
        payload = b"\x01\x02\x03\x04" * 8
        self.assertEqual(PT.read_tile_blob(PT.tile_blob(payload, False)), payload)

    def test_round_trip_compressed(self):
        payload = b"\x00" * 2048          # très compressible
        blob = PT.tile_blob(payload, True)
        self.assertLess(len(blob), len(payload), "le deflate doit servir ici")
        self.assertEqual(PT.read_tile_blob(blob), payload)

    def test_compression_is_skipped_when_it_would_grow(self):
        payload = os.urandom(64)          # incompressible
        blob = PT.tile_blob(payload, True)
        self.assertEqual(PT.read_tile_blob(blob), payload)
        self.assertEqual(blob[PT.TILE_HEADER:], payload, "stocké tel quel")

    def test_corrupted_payload_is_caught(self):
        blob = bytearray(PT.tile_blob(b"abcd" * 16, False))
        blob[-1] ^= 0xFF
        with self.assertRaises(ValueError):
            PT.read_tile_blob(bytes(blob))

    def test_wrong_magic_is_caught(self):
        # Le cas réel : une page d'erreur HTML mise en cache à la place d'une tuile.
        with self.assertRaises(ValueError):
            PT.read_tile_blob(b"<!DOCTYPE html><html><body>404</body></html>")

    def test_truncated_blob_is_caught(self):
        with self.assertRaises(ValueError):
            PT.read_tile_blob(b"DST")


class PublishTree(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.pack_path = os.path.join(self.dir, "heights.pack")
        write_pack(self.pack_path)
        self.pack = PT.Pack(self.pack_path)
        self.out = os.path.join(self.dir, "dist")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def _publish(self, compress=True):
        return PT.publish(self.pack, self.out, "pubtest", "cafe1234", compress)

    def test_publishes_exactly_the_stored_tiles(self):
        written, _raw, _out, _floor = self._publish()
        expected = sum(1 for n in LEVELS for ip in range(12 * n * n) if present(n, ip))
        self.assertEqual(written, expected)
        root = os.path.join(self.out, "pubtest", "cafe1234")
        # Le motif exact, pas un préfixe : "floor.bin" commence lui aussi par "f", et
        # présent.bin a déjà valu de compter des cartes pour des tuiles.
        files = [f for _d, _s, fs in os.walk(root) for f in fs
                 if re.fullmatch(r"f\d+\.bin", f)]
        self.assertEqual(len(files), expected, "aucune tuile absente ne doit être écrite")

    def test_verify_accepts_a_freshly_published_tree(self):
        self._publish()
        bad, checked = PT.verify(self.pack, self.out, "pubtest", "cafe1234")
        self.assertEqual(bad, 0)
        self.assertGreater(checked, 0)

    def test_verify_catches_a_tampered_tile(self):
        # Sans --verify, un octet de travers ne se verrait qu'en jeu, comme un relief faux.
        self._publish()
        root = os.path.join(self.out, "pubtest", "cafe1234")
        victim = None
        for d, _s, fs in os.walk(root):
            for f in fs:
                if f.startswith("f") and f.endswith(".bin"):
                    victim = os.path.join(d, f)
                    break
            if victim:
                break
        blob = bytearray(open(victim, "rb").read())
        blob[-1] ^= 0xFF
        open(victim, "wb").write(bytes(blob))
        bad, _checked = PT.verify(self.pack, self.out, "pubtest", "cafe1234")
        self.assertGreater(bad, 0, "une tuile falsifiée doit être détectée")

    def test_verify_catches_a_missing_tile(self):
        self._publish()
        root = os.path.join(self.out, "pubtest", "cafe1234")
        for d, _s, fs in os.walk(root):
            for f in fs:
                if f.startswith("f") and f.endswith(".bin"):
                    os.remove(os.path.join(d, f))
                    bad, _c = PT.verify(self.pack, self.out, "pubtest", "cafe1234")
                    self.assertGreater(bad, 0, "une tuile manquante doit être détectée")
                    return
        self.fail("aucune tuile publiée")

    def test_presence_map_matches_the_pack(self):
        # La carte est ce qui évite au client un 404 par tuile absente : si elle ment,
        # il demande des tuiles qui n'existent pas ou saute des tuiles qui existent.
        self._publish()
        root = os.path.join(self.out, "pubtest", "cafe1234")
        for n in LEVELS:
            npix = 12 * n * n
            for base in range(0, npix, PT.SHARD_TILES):
                path = os.path.join(root, "n%d" % n, "f%d" % PT.shard_of(base),
                                    "present.bin")
                bits = open(path, "rb").read()
                for ip in range(base, min(base + PT.SHARD_TILES, npix)):
                    i = ip - base
                    self.assertEqual(bool(bits[i >> 3] >> (i & 7) & 1), present(n, ip),
                                     "présence n%d f%d" % (n, ip))

    def test_published_payload_equals_the_pack_bytes(self):
        self._publish()
        root = os.path.join(self.out, "pubtest", "cafe1234")
        n, ip = LEVELS[-1], next(i for i in range(12 * LEVELS[-1] ** 2)
                                 if present(LEVELS[-1], i))
        path = os.path.join(root, "n%d" % n, "f%d" % PT.shard_of(ip), "f%d.bin" % ip)
        got = PT.read_tile_blob(open(path, "rb").read())
        self.assertEqual(got, self.pack.raw_tile(n, ip))
        self.assertEqual(np.frombuffer(got, dtype="<u2")[0], value(n, ip))

    def test_dense_pack_publishes_every_tile(self):
        dense_path = os.path.join(self.dir, "dense.pack")
        write_pack(dense_path, sparse=False)
        pack = PT.Pack(dense_path)
        written, _r, _o, _f = PT.publish(pack, self.out, "dense", "cafe1234", False)
        self.assertEqual(written, sum(12 * n * n for n in LEVELS))
        bad, _c = PT.verify(pack, self.out, "dense", "cafe1234")
        self.assertEqual(bad, 0)


class FloorBundle(unittest.TestCase):
    """Le plancher : les niveaux grossiers servis en un objet unique.

    Les demander une par une coûte ~1020 allers-retours pour 1,9 Mio — des secondes de
    bande passante, des minutes de latence. Ce qui doit tenir ici, c'est que l'objet
    unique livre EXACTEMENT ce que livrent les tuiles isolées : sinon deux clients voient
    deux terrains selon le chemin qu'ils ont pris.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "h.pack")
        write_pack(self.path)
        self.pack = PT.Pack(self.path)

    def test_bundle_carries_every_published_coarse_tile(self):
        entries = PT.read_floor_bundle(PT.floor_bundle(self.pack, False))
        want = {(n, ip) for n in LEVELS for ip in range(12 * n * n)
                if present(n, ip) and n <= PT.FLOOR_NSIDE_MAX}
        self.assertEqual({(n, ip) for n, ip, _b in entries}, want)

    def test_bundle_payloads_are_byte_identical_to_served_tiles(self):
        for n, ip, blob in PT.read_floor_bundle(PT.floor_bundle(self.pack, False)):
            self.assertEqual(PT.read_tile_blob(blob), self.pack.raw_tile(n, ip))

    def test_bundle_stops_at_the_floor_level(self):
        # Un plancher qui embarquerait les niveaux fins pèserait la planète entière.
        entries = PT.read_floor_bundle(PT.floor_bundle(self.pack, False, nside_max=2))
        self.assertEqual({n for n, _i, _b in entries}, {1, 2})

    def test_compression_reaches_the_bundle_too(self):
        small = len(PT.floor_bundle(self.pack, True))
        self.assertLess(small, len(PT.floor_bundle(self.pack, False)))
        for n, ip, blob in PT.read_floor_bundle(PT.floor_bundle(self.pack, True)):
            self.assertEqual(PT.read_tile_blob(blob), self.pack.raw_tile(n, ip))

    def test_a_truncated_bundle_is_caught(self):
        # Un objet coupé en vol ne doit pas se lire comme un plancher partiel valide.
        blob = PT.floor_bundle(self.pack, False)
        with self.assertRaises(ValueError):
            PT.read_floor_bundle(blob[:len(blob) // 2])

    def test_wrong_magic_is_caught(self):
        with self.assertRaises(ValueError):
            PT.read_floor_bundle(b"NOPE" + struct.pack("<II", 1, 0))

    def test_publish_writes_the_bundle_and_verify_checks_it(self):
        out = tempfile.mkdtemp()
        _w, _r, _o, floor_bytes = PT.publish(self.pack, out, "pubtest", "cafe1234", False)
        path = os.path.join(out, "pubtest", "cafe1234", "floor.bin")
        self.assertTrue(os.path.exists(path))
        self.assertEqual(floor_bytes, os.path.getsize(path))
        bad, _c = PT.verify(self.pack, out, "pubtest", "cafe1234")
        self.assertEqual(bad, 0)

    def test_verify_catches_a_corrupted_bundle(self):
        # C'est tout l'intérêt de le vérifier : une divergence entre le plancher et les
        # tuiles ne lève aucune erreur chez le joueur, elle donne un terrain faux.
        out = tempfile.mkdtemp()
        PT.publish(self.pack, out, "pubtest", "cafe1234", False)
        path = os.path.join(out, "pubtest", "cafe1234", "floor.bin")
        blob = bytearray(open(path, "rb").read())
        blob[-1] ^= 0xFF
        open(path, "wb").write(bytes(blob))
        bad, _c = PT.verify(self.pack, out, "pubtest", "cafe1234")
        self.assertGreater(bad, 0)

    def test_verify_catches_a_missing_bundle(self):
        out = tempfile.mkdtemp()
        PT.publish(self.pack, out, "pubtest", "cafe1234", False)
        os.remove(os.path.join(out, "pubtest", "cafe1234", "floor.bin"))
        bad, _c = PT.verify(self.pack, out, "pubtest", "cafe1234")
        self.assertGreater(bad, 0)


def write_modifier_pack(path, tiles):
    """terrainmodifier.pack (DSMP v1) minimal : {(nside, ipix): payload}.

    Écrit par l'encodeur de l'export lui-même, pour que le lecteur de publication soit
    éprouvé sur le format réel et pas sur une copie qui pourrait dériver.
    """
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                    "tools", "planettech", "qgis"))
    from export.planet import dsmp
    levels = {}
    for (nside, ipix), payload in tiles.items():
        levels.setdefault(nside, []).append((ipix, payload))
    dsmp.write_pack(path, [(n, sorted(levels[n])) for n in sorted(levels)],
                    {"planet_name": "modtest", "data_version": "beef0001",
                     "strings": ["a"], "levels": sorted(levels)})


class ModifierPackTree(unittest.TestCase):
    """Le pack de modificateurs : creux à l'extrême, publié sous <planète>.mod."""

    #: n1 et n16 dans le plancher, n64 et n8192 au-delà. n8192 a 805 M de pixels :
    #: le parcourir pixel par pixel, comme l'altitude, ne finirait pas.
    TILES = {(1, 3): b"\x01\x00\x00\x00", (16, 5): b"n16-5", (16, 3071): b"n16-last",
             (64, 7): b"n64-7", (64, 40000): b"n64-40000", (8192, 123456789): b"deep road"}

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.pack_path = os.path.join(self.dir, "terrainmodifier.pack")
        write_modifier_pack(self.pack_path, self.TILES)
        self.pack = PT.open_pack(self.pack_path)
        self.out = os.path.join(self.dir, "dist")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_magic_picks_the_modifier_reader(self):
        self.assertIsInstance(self.pack, PT.DsmpPack)
        self.assertEqual(self.pack.levels, [1, 16, 64, 8192])
        self.assertEqual(self.pack.data_version(), "beef0001")
        for (nside, ipix), payload in self.TILES.items():
            self.assertTrue(self.pack.has_tile(nside, ipix))
            self.assertEqual(self.pack.raw_tile(nside, ipix), payload)
        self.assertFalse(self.pack.has_tile(64, 8))

    def test_only_inhabited_shards_are_written(self):
        written, _r, _o, _f = PT.publish(self.pack, self.out, "modtest.mod", "beef0001", True)
        self.assertEqual(written, len(self.TILES))
        root = os.path.join(self.out, "modtest.mod", "beef0001")
        maps = [os.path.relpath(d, root) for d, _s, fs in os.walk(root) if "present.bin" in fs]
        self.assertEqual(sorted(maps), sorted([
            "n1/f0", "n16/f0", "n64/f0", "n64/f%d" % (40000 // PT.SHARD_TILES),
            "n8192/f%d" % (123456789 // PT.SHARD_TILES)]))
        bad, checked = PT.verify(self.pack, self.out, "modtest.mod", "beef0001")
        self.assertEqual((bad, checked), (0, len(self.TILES)))

    def test_floor_reaches_n16_for_modifiers(self):
        bundle = PT.read_floor_bundle(PT.floor_bundle(self.pack, False))
        self.assertEqual(sorted((n, i) for n, i, _b in bundle),
                         [(1, 3), (16, 5), (16, 3071)])

    def test_a_legacy_pack_without_data_version_is_named_by_its_bytes(self):
        path = os.path.join(self.dir, "old.pack")
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                        "tools", "planettech", "qgis"))
        from export.planet import dsmp
        dsmp.write_pack(path, [(1, [(0, b"x")])], {"planet_name": "old"})
        v1 = PT.open_pack(path).data_version()
        dsmp.write_pack(path, [(1, [(0, b"y")])], {"planet_name": "old"})
        self.assertNotEqual(v1, PT.open_pack(path).data_version())
        self.assertEqual(len(v1), 16)

    def test_a_line_bake_beside_the_pack_does_not_touch_the_tiles_version(self):
        with open(os.path.join(self.dir, "grade_profiles.pack"), "wb") as fh:
            fh.write(b"bake-1")
        self.assertEqual(self.pack.data_version(), "beef0001",
                         "a re-bake must never republish the modifier tiles")

    def test_main_publishes_under_the_mod_body_with_no_tile_res(self):
        rc = PT.main([self.pack_path, "--out", self.out])
        self.assertEqual(rc, 0)
        with open(os.path.join(self.out, "modtest.mod", "latest.json")) as fh:
            entry = json.load(fh)
        self.assertEqual(entry["data_version"], "beef0001")
        self.assertEqual(entry["dataset"], "modifiers")
        self.assertEqual(entry["floor_nside_max"], PT.MODIFIER_FLOOR_NSIDE_MAX)
        self.assertNotIn("tile_res", entry)
        with open(os.path.join(self.out, "channels", "unstable.json")) as fh:
            self.assertIn("modtest.mod", json.load(fh)["planets"])


class LineBakeFile(unittest.TestCase):
    """grade_profiles.pack : un fichier entier, sous son propre corps <planète>.lines."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        chunks = os.path.join(self.dir, "lineplanet_chunks")
        os.makedirs(chunks)
        self.path = os.path.join(chunks, "grade_profiles.pack")
        with open(self.path, "wb") as fh:
            fh.write(b"bake-1" * 100)
        self.out = os.path.join(self.dir, "dist")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_main_publishes_the_file_under_its_own_body(self):
        self.assertEqual(PT.main([self.path, "--out", self.out]), 0)
        with open(os.path.join(self.out, "lineplanet.lines", "latest.json")) as fh:
            entry = json.load(fh)
        self.assertEqual(entry["dataset"], "file")
        self.assertEqual(entry["file"], "grade_profiles.pack")
        self.assertEqual(entry["data_version"], PT.file_version(self.path))
        root = os.path.join(self.out, "lineplanet.lines", entry["data_version"])
        with open(os.path.join(root, "grade_profiles.pack"), "rb") as fh:
            self.assertEqual(PT.read_tile_blob(fh.read()), b"bake-1" * 100)
        self.assertTrue(os.path.exists(os.path.join(root, "manifest.json")))
        from tools.planettech.publish import stream_channels as SC
        self.assertEqual(SC.tree_problems(self.out, "lineplanet.lines", entry), [])
        self.assertEqual(PT.main([self.path, "--out", self.out, "--verify"]), 0)

    def test_a_rebake_is_a_new_version_and_verify_catches_a_stale_copy(self):
        PT.main([self.path, "--out", self.out])
        v1 = PT.file_version(self.path)
        with open(self.path, "wb") as fh:
            fh.write(b"bake-2")
        self.assertNotEqual(PT.file_version(self.path), v1)
        self.assertEqual(PT.verify_file(self.path, self.out, "lineplanet.lines", v1), 1)


class LineBakeRegions(unittest.TestCase):
    """grade_profiles.pack découpé par région (LineBake) : un conteneur DSMP « lines », publié en
    tuiles sous le même corps <planète>.lines, l'en-tête seul dans le plancher."""

    TILES = {(1, 0): b"header", (16, 5): b"region-5", (16, 3071): b"region-last"}

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        chunks = os.path.join(self.dir, "lineplanet_chunks")
        os.makedirs(chunks)
        self.path = os.path.join(chunks, "grade_profiles.pack")
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                        "tools", "planettech", "qgis"))
        from export.planet import dsmp
        levels = {}
        for (nside, ipix), payload in self.TILES.items():
            levels.setdefault(nside, []).append((ipix, payload))
        dsmp.write_pack(self.path, [(n, sorted(levels[n])) for n in sorted(levels)],
                        {"planet_name": "lineplanet", "dataset": "lines", "format": 1,
                         "levels": [1, 16], "floor_nside_max": 1})
        self.out = os.path.join(self.dir, "dist")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_a_regional_bake_is_not_a_whole_file(self):
        self.assertFalse(PT.is_whole_file(self.path))
        pack = PT.open_pack(self.path)
        self.assertEqual((pack.dataset, pack.body_suffix, pack.floor_nside_max), ("lines", ".lines", 1))
        self.assertEqual(pack.data_version(), PT.file_version(self.path),
                         "named by its bytes, like the whole-file bake: the QGIS records still match")

    def test_main_publishes_tiles_under_the_lines_body(self):
        self.assertEqual(PT.main([self.path, "--out", self.out, "--compress"]), 0)
        with open(os.path.join(self.out, "lineplanet.lines", "latest.json")) as fh:
            entry = json.load(fh)
        self.assertEqual(entry["dataset"], "lines")
        self.assertEqual(entry["floor_nside_max"], 1)
        self.assertEqual((entry["nside_min"], entry["nside_max"]), (1, 16))
        self.assertNotIn("tile_res", entry)
        bundle = PT.read_floor_bundle(PT.floor_bundle(PT.open_pack(self.path), False))
        self.assertEqual([(n, i) for n, i, _b in bundle], [(1, 0)], "the floor is the header alone")
        from tools.planettech.publish import stream_channels as SC
        self.assertEqual(SC.tree_problems(self.out, "lineplanet.lines", entry), [])
        self.assertEqual(PT.main([self.path, "--out", self.out, "--verify"]), 0)


if __name__ == "__main__":
    suite = unittest.TestSuite()
    for cls in (TileEnvelope, PublishTree, FloorBundle, ModifierPackTree, LineBakeFile,
                LineBakeRegions):
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(cls))
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
