#!/usr/bin/env python3
"""Tests de tools/publish_tiles.py — l'éclatement d'un pack en arborescence servable.

Ce que publie cet outil part chez les joueurs. Les défauts qu'il pourrait avoir ne lèvent
aucune erreur : un décalage de sharding ou une carte de présence inversée donne un terrain
faux, pas un plantage. D'où ces tests, et d'où le mode --verify de l'outil lui-même.

Run:  python3 test/unit/test_publish_tiles_py.py
"""

import json
import os
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

try:
    import numpy as np
    from tools import publish_tiles as PT
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
        written, _raw, _out = self._publish()
        expected = sum(1 for n in LEVELS for ip in range(12 * n * n) if present(n, ip))
        self.assertEqual(written, expected)
        root = os.path.join(self.out, "pubtest", "cafe1234")
        files = [f for _d, _s, fs in os.walk(root) for f in fs if f.startswith("f")]
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
        written, _r, _o = PT.publish(pack, self.out, "dense", "cafe1234", False)
        self.assertEqual(written, sum(12 * n * n for n in LEVELS))
        bad, _c = PT.verify(pack, self.out, "dense", "cafe1234")
        self.assertEqual(bad, 0)


if __name__ == "__main__":
    suite = unittest.TestSuite()
    for cls in (TileEnvelope, PublishTree):
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(cls))
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
