#!/usr/bin/env python3
"""Contrat d'écriture DSHP v2 de l'exporteur, vu depuis le lecteur.

L'exporteur (Python) écrit le pack, HeightPack (GDScript) le lit. Un désaccord entre les
deux ne se manifesterait pas par une erreur mais par un terrain faux : un en-tête mal
formé se lirait de travers, et des u16 relus comme des float32 donneraient du bruit. Ces
tests figent le contrat côté écriture ; test/unit/test_height_pack_v2.gd le figent côté
lecture, sur les mêmes conventions.

Ce qui est couvert :
  1. La disposition exacte des 32 octets d'en-tête, décodée comme le fait le lecteur.
  2. La version et les flags — un lecteur v1 relirait des u16 comme des float32, donc le
     changement d'encodage DOIT être visible dans l'en-tête.
  3. L'aller-retour de quantification, et surtout la SATURATION : FORMAT_RF n'était pas
     borné et laissait passer des valeurs hors [0,1], qu'un u16 replierait au lieu de les
     saturer — une altitude maximale deviendrait une altitude minimale.
  4. Le retour au format v1, qui doit rester bit pour bit ce qu'il était.

Run:  python3 test/unit/test_dshp_v2_py.py
"""

import os
import struct
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                "tools", "qgis"))

try:
    import numpy as np
except ImportError:  # pragma: no cover
    print("SKIP test_dshp_v2_py: numpy absent")
    sys.exit(0)


class _Blob:
    def __getattr__(self, n):
        return _Blob()

    def __call__(self, *a, **k):
        return _Blob()

    def __getitem__(self, k):
        return _Blob()

    def __iter__(self):
        return iter(())

    def __bool__(self):
        return False

    def __str__(self):
        return ""


class _Any(types.ModuleType):
    def __getattr__(self, n):
        if n.startswith("__"):
            raise AttributeError(n)
        return _Blob()


for _m in ("qgis", "qgis.core", "qgis.PyQt", "qgis.PyQt.QtCore", "osgeo", "osgeo.gdal",
           "processing"):
    _mod = _Any(_m)
    _mod.__file__ = None
    sys.modules[_m] = _mod
sys.modules["qgis"].core = sys.modules["qgis.core"]

_EXPORTER = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "qgis",
    "export_elevation.py"))
_SRC = open(_EXPORTER, encoding="utf-8").read().replace("\nrun_export()\n", "\n")
# __file__ ABSOLU, impérativement : l'exporteur en déduit _tools_dir pour purger de
# sys.modules ce qui vient de son répertoire (la console QGIS réutilise un interpréteur).
# Un chemin relatif ferait pointer _tools_dir sur la racine du dépôt, et la purge
# emporterait __main__ — c'est-à-dire ce fichier de test lui-même.
EXP = {"__name__": "export_elevation_under_test", "__file__": _EXPORTER}
exec(compile(_SRC, _EXPORTER, "exec"), EXP)


def parse_header(head):
    """Décode l'en-tête exactement comme HeightPack.open()."""
    magic, version, tile_res, ns_min, ns_max, flags, blob_start, json_len = \
        struct.unpack("<4s7I", head[:32])
    return dict(magic=magic, version=version, tile_res=tile_res, nside_min=ns_min,
                nside_max=ns_max, flags=flags, blob_start=blob_start, json_len=json_len)


class HeaderLayout(unittest.TestCase):

    def _header(self, u16):
        # build_header rend (en-tête, bourrage) : les cartes de présence s'écrivent entre
        # les deux, donc il ne peut plus rendre un bloc unique.
        EXP["SAMPLE_U16"] = u16
        EXP["SPARSE_EPSILON_M"] = 0.0
        return EXP["build_header"](b'{"planet_name":"t"}', 32, 1, 1024)[0]

    def test_v2_header_fields(self):
        h = self._header(True)
        f = parse_header(h)
        self.assertEqual(f["magic"], b"DSHP")
        self.assertEqual(f["version"], 2, "des u16 doivent s'annoncer en v2")
        self.assertEqual(f["flags"] & 1, 1, "bit0 = échantillons u16")
        self.assertEqual(f["flags"] & 2, 0, "pas encore creux")
        self.assertEqual(f["tile_res"], 32)
        self.assertEqual(f["nside_min"], 1)
        self.assertEqual(f["nside_max"], 1024)

    def test_v1_header_is_unchanged(self):
        f = parse_header(self._header(False))
        self.assertEqual(f["version"], 1)
        self.assertEqual(f["flags"], 0)

    def test_blob_start_is_aligned_and_past_the_manifest(self):
        manifest = b'{"planet_name":"tarsis_3"}'
        EXP["SAMPLE_U16"] = True
        h, pad = EXP["build_header"](manifest, 32, 1, 64)
        f = parse_header(h)
        self.assertEqual(f["json_len"], len(manifest))
        self.assertGreaterEqual(f["blob_start"], 32 + len(manifest))
        self.assertEqual(f["blob_start"] % 16, 0, "blob aligné sur 16 octets")
        self.assertEqual(len(h) + pad, f["blob_start"], "en-tête + bourrage = début du blob")
        self.assertEqual(h[32:32 + len(manifest)], manifest, "manifeste verbatim")


class SparseLayout(unittest.TestCase):
    """Les cartes de présence vivent ENTRE le manifeste et le blob : si blob_start ne les
    comptait pas, le lecteur prendrait des bits de présence pour des échantillons."""

    def _levels(self, ns_min, ns_max):
        out, n = [], ns_min
        while n <= ns_max:
            out.append(n)
            n *= 2
        return out

    def test_sparse_header_reserves_room_for_the_bitmaps(self):
        EXP["SAMPLE_U16"] = True
        manifest = b'{"planet_name":"t"}'
        levels = self._levels(1, 32)
        bitmap_bytes = sum((12 * n * n + 7) // 8 for n in levels)
        head, pad = EXP["build_header"](manifest, 16, 1, 32, bitmap_bytes)
        f = parse_header(head)
        self.assertEqual(f["version"], 2)
        self.assertEqual(f["flags"], 3, "bit0 u16 + bit1 sparse")
        self.assertEqual(len(head), 32 + len(manifest),
                         "l'en-tête s'arrête au manifeste ; l'appelant écrit les cartes")
        self.assertEqual(f["blob_start"], 32 + len(manifest) + bitmap_bytes + pad)
        self.assertEqual(f["blob_start"] % 16, 0)

    def test_dense_header_reserves_nothing(self):
        EXP["SAMPLE_U16"] = True
        head, pad = EXP["build_header"](b"{}", 16, 1, 32, 0)
        f = parse_header(head)
        self.assertEqual(f["flags"] & 2, 0, "pas de bit sparse sans cartes")
        self.assertEqual(f["blob_start"], 32 + 2 + pad)

    def test_presence_bits_are_lsb_first_within_each_byte(self):
        # Convention partagée avec HeightPack.slot_of() : bit i -> octet i>>3, bit i&7.
        # L'inverser décalerait toutes les tuiles d'un niveau sans lever d'erreur.
        npix = 12
        bits = bytearray((npix + 7) // 8)
        present = {0, 1, 7, 8, 11}
        for i in present:
            bits[i >> 3] |= 1 << (i & 7)
        self.assertEqual(bits[0], 0b10000011, "bits 0,1,7 dans le premier octet")
        self.assertEqual(bits[1], 0b00001001, "bits 8 et 11 dans le second")
        for i in range(npix):
            self.assertEqual(bool(bits[i >> 3] >> (i & 7) & 1), i in present)


class SampleEncoding(unittest.TestCase):
    """La formule d'écriture et celle de lecture doivent être réciproques."""

    @staticmethod
    def encode(norm):
        return np.rint(np.clip(np.asarray(norm, dtype=np.float32), 0.0, 1.0)
                       * 65535.0).astype("<u2")

    @staticmethod
    def decode(u):
        # Ce que fait HeightPack._widen_u16().
        return np.asarray(u, dtype=np.float64) / 65535.0

    def test_round_trip_stays_within_one_step(self):
        vals = np.linspace(0.0, 1.0, 4097, dtype=np.float32)
        back = self.decode(self.encode(vals))
        self.assertLess(float(np.abs(back - vals).max()), 1.0 / 65535.0,
                        "l'erreur doit rester sous un pas de quantification")

    def test_one_step_is_well_under_the_contour_spacing(self):
        # 10 700 m d'amplitude / 65 535 pas, contre 50 m d'équidistance des contours.
        self.assertLess(10700.0 / 65535.0, 0.2)

    def test_out_of_range_saturates_instead_of_wrapping(self):
        # FORMAT_RF n'était pas borné : sans le clip, -0.1 deviendrait 59 000 et un
        # sommet passerait sous le niveau de la mer.
        self.assertEqual(int(self.encode([-0.1])[0]), 0)
        self.assertEqual(int(self.encode([1.5])[0]), 65535)

    def test_bounds_are_exact(self):
        self.assertEqual(int(self.encode([0.0])[0]), 0)
        self.assertEqual(int(self.encode([1.0])[0]), 65535)

    def test_encoding_is_little_endian_u16(self):
        raw = self.encode([1.0, 0.0]).tobytes()
        self.assertEqual(len(raw), 4, "deux échantillons = quatre octets")
        self.assertEqual(raw[:2], b"\xff\xff")
        self.assertEqual(struct.unpack("<H", raw[:2])[0], 65535)


class DataVersion(unittest.TestCase):

    def test_encoding_change_invalidates_the_cache(self):
        # Passer de float32 à u16 change toutes les altitudes d'une fraction de mètre.
        # Si l'empreinte ne bougeait pas, les clients garderaient l'ancien terrain.
        EXP["PLANET_NAME"], EXP["PLANET_RADIUS"] = "tarsis_3", 6356000.0
        EXP["ELEV_MIN"], EXP["ELEV_MAX"] = -1700.0, 9000.0
        pts = np.zeros((16, 3))
        EXP["SPARSE_EPSILON_M"] = 1.0
        EXP["SAMPLE_U16"] = True
        a = EXP["compute_data_version"](pts)
        EXP["SAMPLE_U16"] = False
        b = EXP["compute_data_version"](pts)
        self.assertNotEqual(a, b, "l'encodage doit entrer dans data_version")

    def test_epsilon_change_invalidates_the_cache(self):
        # Changer epsilon change quelles tuiles existent, donc le terrain reconstruit.
        EXP["PLANET_NAME"], EXP["PLANET_RADIUS"] = "tarsis_3", 6356000.0
        EXP["ELEV_MIN"], EXP["ELEV_MAX"] = -1700.0, 9000.0
        EXP["SAMPLE_U16"] = True
        pts = np.zeros((16, 3))
        EXP["SPARSE_EPSILON_M"] = 1.0
        a = EXP["compute_data_version"](pts)
        EXP["SPARSE_EPSILON_M"] = 10.0
        b = EXP["compute_data_version"](pts)
        EXP["SPARSE_EPSILON_M"] = 1.0
        self.assertNotEqual(a, b, "epsilon doit entrer dans data_version")


class PackWriter(unittest.TestCase):
    """write_pack() de bout en bout : deux passes, cartes de présence, élagage en cascade.

    C'est le code le plus risqué de l'exporteur, et un export réel de tarsis_3 dure ~35 h :
    le découvrir cassé après coup coûterait la journée. Ces tests le font tourner sur une
    pyramide synthétique et RELISENT le pack produit pour vérifier la seule propriété qui
    compte — que le terrain reconstruit par le client reste à moins d'epsilon du vrai.
    """

    TR = 8
    LEVELS = [1, 2, 4, 8]
    EPS = 0.01          # elev_range = 1, donc 1 unité normalisée = 1 « mètre »

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        EXP["TILE_RES"] = self.TR
        EXP["TILE_BATCH"] = 16
        EXP["SAMPLE_U16"] = True
        EXP["SPARSE_EPSILON_M"] = self.EPS

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    # -- terrain synthétique, fonction continue de la position ------------------
    def _field(self, lon, lat):
        smooth = 0.5 + 0.2 * np.sin(np.radians(lon))
        bump = 0.25 * np.exp(-(((lon - 30.0) ** 2 + (lat - 10.0) ** 2) / 50.0))
        return (smooth + bump).astype(np.float32)

    def _sampler(self):
        hpx = EXP["hpx"]

        def sample(nside, group):
            out = []
            for ip in group:
                lon, lat = hpx.get_tile_grid_lonlat(nside, ip, self.TR)
                out.append(self._field(lon, lat))
            return np.stack(out)
        return sample

    def _write(self, sparse_eps):
        EXP["SPARSE_EPSILON_M"] = sparse_eps
        manifest = b'{"planet_name":"wp"}'
        total = sum(12 * n * n for n in self.LEVELS)
        path = os.path.join(self.dir, "heights.pack")
        kept, tot = EXP["write_pack"](path, self.dir, manifest, self.LEVELS, total,
                                      1.0, self._sampler())
        return path, kept, tot

    # -- relecture indépendante, comme le ferait le client ----------------------
    def _read(self, path):
        with open(path, "rb") as fh:
            blob = fh.read()
        h = parse_header(blob)
        off = 32 + h["json_len"]
        present, slots = {}, {}
        for n in self.LEVELS:
            npix = 12 * n * n
            nb = (npix + 7) // 8
            bits = blob[off:off + nb]
            off += nb
            present[n] = [bool(bits[i >> 3] >> (i & 7) & 1) for i in range(npix)]
            slots[n] = np.cumsum([0] + present[n][:-1]).tolist()
        base, tiles = h["blob_start"], {}
        for n in self.LEVELS:
            npix = 12 * n * n
            for ip in range(npix):
                if not present[n][ip]:
                    continue
                o = base + slots[n][ip] * self.TR * self.TR * 2
                raw = np.frombuffer(blob, dtype="<u2", count=self.TR * self.TR,
                                    offset=o).astype(np.float64) / 65535.0
                tiles[(n, ip)] = raw.reshape(self.TR, self.TR)
            base += sum(present[n]) * self.TR * self.TR * 2
        return h, present, tiles

    def _reconstruct(self, present, tiles, nside, ipix):
        """Ce que le client obtiendrait : la tuile, ou l'upsample de sa reconstruction."""
        if present[nside][ipix]:
            return tiles[(nside, ipix)]
        parent = self._reconstruct(present, tiles, nside // 2, ipix >> 2)
        up = EXP["_upsampler"](self.TR)
        k, half = ipix & 3, self.TR // 2
        dx, dy = k & 1, (k >> 1) & 1
        return up(parent[dy * half:(dy + 1) * half, dx * half:(dx + 1) * half])

    # -- les tests --------------------------------------------------------------
    def test_smooth_terrain_prunes_heavily(self):
        _p, kept, tot = self._write(self.EPS)
        self.assertLess(kept, tot * 0.6,
                        "un relief lisse doit s'élaguer largement (%d/%d gardées)" % (kept, tot))
        self.assertGreaterEqual(kept, 12, "le niveau le plus grossier est toujours gardé")

    def test_epsilon_zero_keeps_everything(self):
        _p, kept, tot = self._write(0.0)
        self.assertEqual(kept, tot, "epsilon nul = pack dense")

    def test_reconstruction_never_exceeds_epsilon(self):
        # LA propriété. On relit le pack et on reconstruit chaque tuile du niveau le plus
        # fin exactement comme le client, puis on compare au terrain vrai.
        path, _k, _t = self._write(self.EPS)
        h, present, tiles = self._read(path)
        self.assertEqual(h["flags"], 3, "u16 + sparse")
        hpx = EXP["hpx"]
        fine = max(self.LEVELS)
        worst = 0.0
        for ip in range(12 * fine * fine):
            lon, lat = hpx.get_tile_grid_lonlat(fine, ip, self.TR)
            truth = self._field(lon, lat)
            got = self._reconstruct(present, tiles, fine, ip)
            worst = max(worst, float(np.abs(got - truth).max()))
        # epsilon + un pas de quantification : une tuile GARDÉE porte aussi l'arrondi u16.
        self.assertLessEqual(worst, self.EPS + 1.0 / 65535.0,
                             "erreur reconstruite %.6f > epsilon %.6f" % (worst, self.EPS))

    def test_blob_size_matches_the_presence_maps(self):
        # Un décalage d'un octet entre cartes et blob ne lèverait aucune erreur : il
        # décalerait toutes les tuiles.
        path, kept, _t = self._write(self.EPS)
        h, present, _tiles = self._read(path)
        expected = h["blob_start"] + kept * self.TR * self.TR * 2
        self.assertEqual(os.path.getsize(path), expected,
                         "taille du fichier = en-tête + cartes + tuiles gardées")
        self.assertEqual(sum(sum(v) for v in present.values()), kept)

    def test_no_temp_files_are_left_behind(self):
        self._write(self.EPS)
        leftovers = [f for f in os.listdir(self.dir) if f.startswith(".")]
        self.assertEqual(leftovers, [], "les temporaires doivent être nettoyés")


if __name__ == "__main__":
    unittest.main(verbosity=2)
