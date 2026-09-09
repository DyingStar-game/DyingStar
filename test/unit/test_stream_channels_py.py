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


class GarbageCollection(unittest.TestCase):
    """La suppression des versions mortes.

    Il en faut une : une version de tarsis_3 à 198 m pèse 5,1 millions de fichiers et
    20 Gio, si bien que le volume se remplit en trois publications. Mais c'est aussi
    l'outil le plus dangereux du lot — il efface irréversiblement des millions de
    fichiers — d'où ces tests sur ce qu'il refuse de toucher.
    """

    def setUp(self):
        self.dist = tempfile.mkdtemp()

    def _tree(self, planet, version, files=3):
        root = os.path.join(self.dist, planet, version, "n1", "f0")
        os.makedirs(root, exist_ok=True)
        for i in range(files):
            open(os.path.join(root, "f%d.bin" % i), "wb").write(b"x" * 100)
        return os.path.join(self.dist, planet, version)

    def test_a_version_no_channel_cites_is_dead(self):
        self._tree("tarsis_3", "old")
        self._tree("tarsis_3", "new")
        SC.record(self.dist, "dev", "tarsis_3", entry("new"))
        dead = [(p, v) for p, v, _d in SC.dead_versions(self.dist)]
        self.assertEqual(dead, [("tarsis_3", "old")])

    def test_a_version_cited_by_any_rung_survives(self):
        # Y compris unstable : une version fraîchement publiée que personne n'a promue
        # est du travail en cours, pas un déchet.
        self._tree("tarsis_3", "fresh")
        SC.record(self.dist, "unstable", "tarsis_3", entry("fresh"))
        self.assertEqual(SC.dead_versions(self.dist), [])

    def test_a_version_still_in_prod_survives_a_newer_one_elsewhere(self):
        # Le cas qui compte : prod traîne derrière, et sa version ne doit pas partir
        # parce que dev est passé à autre chose.
        self._tree("tarsis_3", "v1")
        self._tree("tarsis_3", "v2")
        SC.record(self.dist, "prod", "tarsis_3", entry("v1"))
        SC.record(self.dist, "dev", "tarsis_3", entry("v2"))
        self.assertEqual(SC.dead_versions(self.dist), [])

    def test_the_latest_pointer_does_not_grant_immortality(self):
        # latest.json suit la dernière publication : s'il faisait autorité, une version
        # publiée puis abandonnée ne pourrait jamais être supprimée.
        self._tree("tarsis_3", "abandonnee")
        os.makedirs(os.path.join(self.dist, "tarsis_3"), exist_ok=True)
        with open(os.path.join(self.dist, "tarsis_3", "latest.json"), "w") as fh:
            json.dump({"data_version": "abandonnee"}, fh)
        dead = [(p, v) for p, v, _d in SC.dead_versions(self.dist)]
        self.assertEqual(dead, [("tarsis_3", "abandonnee")])

    def test_dry_run_measures_without_deleting(self):
        # Le mode par défaut, et il le reste : effacer cinq millions de fichiers ne se
        # rejoue pas.
        vdir = self._tree("tarsis_3", "old", files=5)
        found = SC.collect(self.dist, dry_run=True)
        self.assertEqual([(p, v, f) for p, v, f, _s in found], [("tarsis_3", "old", 5)])
        self.assertTrue(os.path.isdir(vdir))

    def test_collect_removes_only_the_dead_tree(self):
        dead = self._tree("tarsis_3", "old")
        live = self._tree("tarsis_3", "new")
        SC.record(self.dist, "dev", "tarsis_3", entry("new"))
        SC.collect(self.dist, dry_run=False)
        self.assertFalse(os.path.exists(dead))
        self.assertTrue(os.path.isdir(live))

    def test_the_channels_directory_is_never_a_planet(self):
        # channels/ est un frère des répertoires de corps : le prendre pour une planète
        # reviendrait à supprimer les manifestes eux-mêmes.
        self._tree("tarsis_3", "v1")
        SC.record(self.dist, "dev", "tarsis_3", entry("v1"))
        SC.collect(self.dist, dry_run=False)
        self.assertTrue(os.path.exists(SC.channel_path(self.dist, "dev")))

    def test_nothing_to_collect_is_not_an_error(self):
        self._tree("tarsis_3", "v1")
        SC.record(self.dist, "dev", "tarsis_3", entry("v1"))
        self.assertEqual(SC.collect(self.dist, dry_run=False), [])

    def test_it_counts_files_as_well_as_bytes(self):
        # Sur un volume à table d'inodes fixe ce sont les fichiers qui s'épuisent en
        # premier : 5,1 M par version contre 16,7 M libres.
        self._tree("tarsis_3", "old", files=7)
        found = SC.collect(self.dist, dry_run=True)
        self.assertEqual(found[0][2], 7)
        self.assertEqual(found[0][3], 700)


if __name__ == "__main__":
    suite = unittest.TestSuite()
    for cls in (Lifecycle, GarbageCollection):
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(cls))
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
