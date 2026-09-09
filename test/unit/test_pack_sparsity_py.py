#!/usr/bin/env python3
"""Tests de tools/planettech/analyze_pack_sparsity.py — l'outil qui décide dense vs pack creux.

Cet outil produit LE chiffre sur lequel se prend une décision d'architecture (voir
docs/PLANET_CHUNK_STREAMING.md, phase 1) et il est destiné à être rejoué par planète et
après chaque modification de terrain. Un outil de décision qui se trompe en silence est
pire que pas d'outil, d'où ces tests.

Ce qui est couvert :
  1. Le mapping de quadrant NESTED. C'est la seule chose vraiment délicate : si l'enfant
     k était rattaché au mauvais quadrant du parent, l'outil rapporterait des erreurs
     énormes partout et on conclurait « pack creux inutile » — un faux négatif silencieux.
  2. Les deux extrêmes : une pyramide parfaitement prédictible s'élague à 100 %, une
     pyramide bruitée à 0 %.
  3. La conversion en mètres via max_height, sans quoi tous les seuils sont faux.
  4. Le désaccord de nom entre manifest.json et en-tête du pack — arrivé pour de vrai
     sur tarsis_3/tarsis_4, et des packs de cette époque traînent encore.
  5. L'élagage EN CASCADE : la garantie que l'erreur visible reste bornée par epsilon
     quelle que soit la profondeur, et le fait qu'il élague moins que la borne naïve.
     C'est l'algorithme que le baker doit implémenter ; s'il se trompait, on
     dimensionnerait le stockage sur un taux qu'aucun bake réel n'atteint.

Run:  python3 test/unit/test_pack_sparsity_py.py
"""

import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

try:
    import numpy as np
    import tools.planettech.analyze_pack_sparsity as aps
except ImportError as exc:  # numpy absent (le job lint CI est stdlib-only)
    print("SKIP test_pack_sparsity_py: %s" % exc)
    sys.exit(0)


TILE_RES = 8
NSIDE_MAX = 2


def write_pack(path, tiles_by_level, planet_name="testworld", max_height=1000.0,
               nside_min=1, nside_max=NSIDE_MAX, tile_res=TILE_RES):
    """Écrit un DSHP v1 minimal. tiles_by_level : {nside: array (12*nside^2, tr, tr)}."""
    manifest = json.dumps({"planet_name": planet_name, "max_height": max_height}).encode()
    header = struct.pack("<7I", 1, tile_res, nside_min, nside_max, 0,
                         4 + 28 + len(manifest), len(manifest))
    with open(path, "wb") as fh:
        fh.write(aps.MAGIC + header + manifest)
        ns = nside_min
        while ns <= nside_max:
            fh.write(np.asarray(tiles_by_level[ns], dtype="<f4").tobytes())
            ns *= 2


def constant_pyramid(value=0.5):
    """Chaque tuile est plate : l'upsample du parent la reproduit exactement."""
    out = {}
    ns = 1
    while ns <= NSIDE_MAX:
        out[ns] = np.full((12 * ns * ns, TILE_RES, TILE_RES), value, dtype="<f4")
        ns *= 2
    return out


class QuadrantMapping(unittest.TestCase):
    """L'enfant k doit être prédit depuis le quadrant (k&1, k>>1) du parent."""

    def test_correct_quadrant_beats_every_other(self):
        rng = np.random.default_rng(7)
        # Parent dont les quatre quadrants sont franchement différents, pour que se
        # tromper de quadrant soit visible.
        parent = np.zeros((TILE_RES, TILE_RES), dtype="<f4")
        half = TILE_RES // 2
        for dy in (0, 1):
            for dx in (0, 1):
                parent[dy * half:(dy + 1) * half, dx * half:(dx + 1) * half] = 0.1 + 0.3 * (2 * dy + dx)

        up = aps._upsampler(TILE_RES)
        levels = {1: np.zeros((12, TILE_RES, TILE_RES), dtype="<f4"),
                  2: np.zeros((48, TILE_RES, TILE_RES), dtype="<f4")}
        levels[1][0] = parent
        # Chaque enfant EST l'upsample de son quadrant : erreur nulle si le mapping est bon.
        for k in range(4):
            dx, dy = k & 1, (k >> 1) & 1
            quad = parent[dy * half:(dy + 1) * half, dx * half:(dx + 1) * half]
            levels[2][k] = up(quad)

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "heights.pack")
            write_pack(path, levels)
            pack = aps.Pack(path)
            for k in range(4):
                good = aps.predict_error_m(pack, up, 1, 0, k)
                self.assertLess(good, 1e-3, "quadrant correct pour k=%d" % k)
                for wrong in range(4):
                    if wrong == k:
                        continue
                    # On prédit l'enfant k depuis le quadrant de `wrong`.
                    dxw, dyw = wrong & 1, (wrong >> 1) & 1
                    quad = pack.tile(1, 0)[dyw * half:(dyw + 1) * half,
                                           dxw * half:(dxw + 1) * half]
                    err = float(np.abs(up(quad) - pack.tile(2, k)).max() * pack.max_height)
                    self.assertGreater(err, good + 1.0,
                                       "le mauvais quadrant %d doit être pire que %d" % (wrong, k))


class PruningRates(unittest.TestCase):

    def test_flat_pyramid_is_fully_prunable(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "heights.pack")
            write_pack(path, constant_pyramid())
            pack = aps.Pack(path)
            per_level = aps.analyse(pack, [1.0])
            self.assertEqual(per_level[0]["prunable"]["1.0"], 1.0)
            proj = aps.project(pack, per_level, 1.0)
            # Seul le niveau le plus grossier (12 tuiles, sans parent) survit.
            self.assertEqual(proj["tiles_sparse"], 12)
            self.assertEqual(proj["tiles_dense"], 12 + 48)

    def test_noisy_pyramid_is_not_prunable(self):
        rng = np.random.default_rng(3)
        levels = constant_pyramid()
        levels[2] = rng.random((48, TILE_RES, TILE_RES)).astype("<f4")
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "heights.pack")
            write_pack(path, levels)  # max_height 1000 m, bruit ~[0,1] -> des centaines de m
            per_level = aps.analyse(aps.Pack(path), [1.0, 10.0])
            self.assertEqual(per_level[0]["prunable"]["1.0"], 0.0)
            self.assertEqual(per_level[0]["prunable"]["10.0"], 0.0)

    def test_thresholds_are_metres_not_normalised_units(self):
        """Un écart de 0,01 en valeur normalisée vaut 10 m si max_height = 1000."""
        levels = constant_pyramid(0.5)
        levels[2][:] = 0.51
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "heights.pack")
            write_pack(path, levels, max_height=1000.0)
            per_level = aps.analyse(aps.Pack(path), [9.0, 11.0])
            self.assertEqual(per_level[0]["prunable"]["9.0"], 0.0, "9 m < 10 m d'écart")
            self.assertEqual(per_level[0]["prunable"]["11.0"], 1.0, "11 m > 10 m d'écart")


class ManifestNaming(unittest.TestCase):

    def test_loose_manifest_wins_and_mismatch_is_reported(self):
        """Le cas réel : un outil réécrivait le manifest.json et jamais l'en-tête."""
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "heights.pack")
            write_pack(path, constant_pyramid(), planet_name="tarsis_4")
            with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as fh:
                json.dump({"planet_name": "tarsis_3"}, fh)
            pack = aps.Pack(path)
            self.assertEqual(pack.planet_name, "tarsis_3")
            self.assertEqual(pack.name_mismatch, ("tarsis_3", "tarsis_4"))

    def test_no_mismatch_when_names_agree(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "heights.pack")
            write_pack(path, constant_pyramid(), planet_name="tarsis_7")
            with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as fh:
                json.dump({"planet_name": "tarsis_7"}, fh)
            self.assertIsNone(aps.Pack(path).name_mismatch)


class CascadePruning(unittest.TestCase):
    """cascade_prune() rejoue la décision réelle du baker ; bound_prune() la borne naïve."""

    TILE = 8
    TARGET = 8   # racine n1 -> n2 -> n4 -> n8 : trois niveaux de cascade

    def _drifting(self, step):
        """Chaque niveau s'écarte de `step` du précédent. Tuiles constantes, donc
        l'upsample d'un parent reproduit exactement sa valeur."""
        def get_tile(nside, _ipix):
            depth = int(round(np.log2(nside)))
            return np.full((self.TILE, self.TILE), depth * step, dtype=np.float32)
        return get_tile

    def test_cascade_prunes_less_than_the_naive_bound(self):
        # Dérive de 0,6 par niveau, epsilon = 1 :
        #   borne   : chaque enfant est à 0,6 de son parent RÉEL -> tout élagable
        #   cascade : au niveau 2, la reconstruction est restée à la valeur racine,
        #             donc l'écart vaut 1,2 > 1 -> non élagable
        get_tile = self._drifting(0.6)
        cp, ct, worst = aps.cascade_prune(get_tile, 1, 0, self.TARGET, 1.0, self.TILE)
        bp, bt = aps.bound_prune(get_tile, 1, 0, self.TARGET, 1.0, self.TILE)

        self.assertEqual(bp.get(2), bt[2], "borne : niveau 2 entièrement élagable")
        self.assertEqual(bp.get(4), bt[4], "borne : niveau 4 entièrement élagable")
        self.assertEqual(cp.get(2), ct[2], "cascade : niveau 2 encore élagable")
        self.assertEqual(cp.get(4, 0), 0,
                         "cascade : niveau 4 NON élagable, l'erreur s'est cumulée")
        self.assertLess(sum(cp.values()), sum(bp.values()),
                        "la cascade doit élaguer strictement moins que la borne")

    def test_pruned_error_never_exceeds_epsilon(self):
        """La garantie de l'algorithme : comparer à la reconstruction borne l'erreur
        visible à epsilon, quelle que soit la profondeur."""
        for step in (0.1, 0.3, 0.9, 2.0):
            for eps in (0.5, 1.0, 5.0):
                _cp, _ct, worst = aps.cascade_prune(
                    self._drifting(step), 1, 0, self.TARGET, eps, self.TILE)
                self.assertLessEqual(worst, eps,
                                     "step=%s eps=%s : erreur élaguée %s > eps"
                                     % (step, eps, worst))

    def test_smooth_pyramid_prunes_entirely_in_both_modes(self):
        flat = lambda nside, ipix: np.full((self.TILE, self.TILE), 0.25, dtype=np.float32)
        cp, ct, worst = aps.cascade_prune(flat, 1, 0, self.TARGET, 1e-6, self.TILE)
        bp, bt = aps.bound_prune(flat, 1, 0, self.TARGET, 1e-6, self.TILE)
        self.assertEqual(sum(cp.values()), sum(ct.values()))
        self.assertEqual(sum(bp.values()), sum(bt.values()))
        self.assertEqual(worst, 0.0)

    def test_every_descendant_is_visited_once(self):
        seen = []

        def counting(nside, ipix):
            seen.append((nside, ipix))
            return np.zeros((self.TILE, self.TILE), dtype=np.float32)

        _cp, ct, _w = aps.cascade_prune(counting, 1, 0, self.TARGET, 1.0, self.TILE)
        # racine n1 -> 4 enfants n2 -> 16 n4 -> 64 n8
        self.assertEqual(ct[2], 4)
        self.assertEqual(ct[4], 16)
        self.assertEqual(ct[8], 64)
        self.assertEqual(len(seen), 1 + 4 + 16 + 64)


if __name__ == "__main__":
    unittest.main(verbosity=2)
