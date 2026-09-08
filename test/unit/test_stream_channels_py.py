#!/usr/bin/env python3
"""Tests de tools/stream_channels.py — les canaux de publication et la promotion.

Ce que ces tests protègent : une promotion fait passer une version d'un cran au suivant
sans recopier un octet, et c'est précisément ce qui garantit que client et serveur voient
le même terrain. Les défauts possibles ne lèvent rien — un canal à moitié promu, un
pointeur vers une arborescence incomplète — et se découvrent devant un joueur qui traverse
le sol.

Run:  python3 test/unit/test_stream_channels_py.py
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
from tools import stream_channels as SC


def entry(version="v1", floor=8, nside=64):
    return {"data_version": version, "nside_min": 1, "nside_max": nside,
            "tile_res": 32, "shard_tiles": 4096, "floor_nside_max": floor}


class Lifecycle(unittest.TestCase):

    def setUp(self):
        self.dist = tempfile.mkdtemp()

    def _tree(self, planet, version, floor=True, nside=64):
        """Une arborescence publiée plausible, celle que la promotion exige."""
        root = os.path.join(self.dist, planet, version)
        os.makedirs(os.path.join(root, "n%d" % nside), exist_ok=True)
        open(os.path.join(root, "manifest.json"), "w").write("{}")
        if floor:
            open(os.path.join(root, "floor.bin"), "wb").write(b"x")
        return root

    def test_the_ladder_goes_from_unstable_to_prod(self):
        self.assertEqual(SC.CHANNELS, ["unstable", "dev", "preprod", "prod"])
        self.assertIsNone(SC.previous_channel("unstable"))
        self.assertEqual(SC.previous_channel("prod"), "preprod")

    def test_a_publication_only_feeds_the_first_rung(self):
        # Une version ne doit pas pouvoir atteindre les joueurs sans avoir traversé les
        # crans intermédiaires : publier n'écrit que dans le premier.
        self.assertEqual(SC.PUBLISH_CHANNEL, "unstable")

    def test_recording_a_planet_leaves_the_others_alone(self):
        SC.record(self.dist, "dev", "tarsis_1", entry("a"))
        SC.record(self.dist, "dev", "tarsis_3", entry("b"))
        planets = SC.load(self.dist, "dev")["planets"]
        self.assertEqual(sorted(planets), ["tarsis_1", "tarsis_3"])
        self.assertEqual(planets["tarsis_1"]["data_version"], "a")

    def test_promotion_moves_the_pointer_one_rung(self):
        self._tree("tarsis_3", "v1")
        SC.record(self.dist, "unstable", "tarsis_3", entry("v1"))
        moved, problems = SC.promote(self.dist, "dev")
        self.assertEqual(problems, [])
        self.assertEqual(moved, [("tarsis_3", None, "v1")])
        self.assertEqual(
            SC.load(self.dist, "dev")["planets"]["tarsis_3"]["data_version"], "v1")

    def test_promotion_copies_no_tiles(self):
        # La propriété qui rend la promotion sûre ET instantanée : l'arborescence est
        # partagée, donc un octet ne peut pas changer entre deux canaux.
        self._tree("tarsis_3", "v1")
        SC.record(self.dist, "unstable", "tarsis_3", entry("v1"))
        before = sorted(os.listdir(os.path.join(self.dist, "tarsis_3")))
        SC.promote(self.dist, "dev")
        self.assertEqual(sorted(os.listdir(os.path.join(self.dist, "tarsis_3"))), before)

    def test_a_version_climbs_one_rung_at_a_time(self):
        self._tree("tarsis_3", "v1")
        SC.record(self.dist, "unstable", "tarsis_3", entry("v1"))
        # prod ne peut rien prendre : preprod est vide.
        _m, problems = SC.promote(self.dist, "prod")
        self.assertTrue(problems)
        self.assertEqual(SC.load(self.dist, "prod")["planets"], {})
        for rung in ("dev", "preprod", "prod"):
            _m, problems = SC.promote(self.dist, rung)
            self.assertEqual(problems, [], rung)
        self.assertEqual(
            SC.load(self.dist, "prod")["planets"]["tarsis_3"]["data_version"], "v1")

    def test_promoting_one_body_leaves_the_others_where_they_were(self):
        # Ré-exporter tarsis_3 ne doit pas embarquer dix-huit corps non retestés.
        for p in ("tarsis_1", "tarsis_3"):
            self._tree(p, "v1")
            SC.record(self.dist, "unstable", p, entry("v1"))
        SC.promote(self.dist, "dev")
        self._tree("tarsis_3", "v2")
        SC.record(self.dist, "unstable", "tarsis_3", entry("v2"))
        SC.promote(self.dist, "dev", ["tarsis_3"])
        dev = SC.load(self.dist, "dev")["planets"]
        self.assertEqual(dev["tarsis_3"]["data_version"], "v2")
        self.assertEqual(dev["tarsis_1"]["data_version"], "v1")

    def test_an_incomplete_tree_blocks_the_promotion(self):
        # On promeut un POINTEUR : s'il désigne une arborescence incomplète, le canal
        # supérieur casse sans que rien ne le dise.
        SC.record(self.dist, "unstable", "tarsis_3", entry("ghost"))
        _m, problems = SC.promote(self.dist, "dev")
        self.assertTrue(problems)
        self.assertEqual(SC.load(self.dist, "dev")["planets"], {})

    def test_an_announced_floor_must_exist(self):
        self._tree("tarsis_3", "v1", floor=False)
        SC.record(self.dist, "unstable", "tarsis_3", entry("v1", floor=8))
        _m, problems = SC.promote(self.dist, "dev")
        self.assertTrue(any("floor.bin" in p for p in problems))

    def test_a_missing_finest_level_blocks_the_promotion(self):
        self._tree("tarsis_3", "v1", nside=64)
        SC.record(self.dist, "unstable", "tarsis_3", entry("v1", nside=256))
        _m, problems = SC.promote(self.dist, "dev")
        self.assertTrue(any("n256" in p for p in problems))

    def test_promotion_is_all_or_nothing(self):
        # Un canal à moitié promu mêle deux exports sans que rien ne le dise — pire que
        # pas promu du tout.
        self._tree("tarsis_1", "v1")
        SC.record(self.dist, "unstable", "tarsis_1", entry("v1"))
        SC.record(self.dist, "unstable", "tarsis_3", entry("ghost"))
        moved, problems = SC.promote(self.dist, "dev")
        self.assertTrue(problems)
        self.assertEqual(moved, [])
        self.assertEqual(SC.load(self.dist, "dev")["planets"], {}, "tarsis_1 non plus")

    def test_promotion_records_where_it_came_from(self):
        self._tree("tarsis_3", "v1")
        SC.record(self.dist, "unstable", "tarsis_3", entry("v1"))
        SC.promote(self.dist, "dev")
        data = SC.load(self.dist, "dev")
        self.assertEqual(data["promoted_from"], "unstable")
        self.assertTrue(data["promoted_at"].endswith("Z"))

    def test_a_missing_channel_reads_as_empty_not_as_an_error(self):
        self.assertEqual(SC.load(self.dist, "prod")["planets"], {})

    def test_the_manifest_is_replaced_atomically(self):
        # Un client qui lit pendant une promotion doit voir l'ancien manifeste ou le
        # nouveau, jamais un fichier à moitié écrit.
        self._tree("tarsis_3", "v1")
        SC.record(self.dist, "unstable", "tarsis_3", entry("v1"))
        SC.promote(self.dist, "dev")
        d = os.path.join(self.dist, "channels")
        self.assertEqual([f for f in os.listdir(d) if f.endswith(".tmp")], [])
        json.load(open(os.path.join(d, "dev.json")))


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Lifecycle)
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
