#!/usr/bin/env python3
"""Tests de tools/planettech/publish/publish_remote.py — publier un export sur le serveur par SSH.

Le transport est injecté : `run(cmd)` reçoit les commandes ssh / scp / rsync. Le test
d'intégration joue le serveur dans un dossier local — une commande ssh y est exécutée par
`sh -c` avec ce dossier pour $HOME, une copie par un simple cp — si bien que publish_tiles.py
tourne réellement « sur le serveur », avec le code que publish_remote y a copié.

Run:  python3 test/unit/test_publish_remote_py.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, _REPO)
sys.path.insert(0, os.path.join(_REPO, "tools", "planettech", "qgis"))

from tools.planettech.publish import publish_remote as PR      # noqa: E402
from tools.planettech.publish import publish_tiles as PT       # noqa: E402
from export.planet import dsmp                                  # noqa: E402
import link_modifiers                                           # noqa: E402
from export.planet.dsmp_strings import StringTable              # noqa: E402


def _cfg(**over):
    cfg = dict(PR._DEFAULTS, ssh=HOST, http="")
    cfg.update(over)
    return cfg


HOST = "deploy@tiles.example"
LOGIN_SHELL = shutil.which("tcsh") or shutil.which("csh") or "sh"


class FakeServer:
    """Le serveur, dans un dossier : $HOME distant = home, les commandes y tournent vraiment."""

    def _remote(self, spec):
        remote = spec.split(":", 1)[1]
        return remote if os.path.isabs(remote) else os.path.join(self.home, remote)

    def __init__(self, root):
        self.home = os.path.join(root, "home")
        os.makedirs(self.home)
        self.calls = []

    def run(self, cmd):
        self.calls.append(cmd)
        if cmd[0] == "ssh":
            # sshd hands the line to the user's LOGIN shell: csh for root on FreeBSD, which is
            # the real server — `if …; then … fi` failed there (2026-11-18).
            proc = subprocess.run([LOGIN_SHELL, "-c", cmd[-1]], cwd=self.home,
                                  capture_output=True, text=True)
            return proc.returncode, proc.stdout + proc.stderr
        if cmd[0] in ("scp", "rsync"):
            src, dst = cmd[-2], cmd[-1]
            if dst.startswith(HOST + ":"):
                dest = self._remote(dst)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copyfile(src, dest)
            else:
                if not os.path.exists(self._remote(src)):
                    return 1, "no such file"
                shutil.copyfile(self._remote(src), dst)
            return 0, ""
        raise AssertionError("commande inattendue %r" % (cmd,))


class Config(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _ini(self, name, text):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return path

    def test_nothing_configured_means_nothing_published(self):
        cfg = PR.load_config({}, ini_path="/nope", client_ini="/nope")
        self.assertFalse(PR.configured(cfg))
        self.assertEqual(cfg["dist"], "/var/www/dist")
        self.assertEqual(cfg["channel"], "unstable")

    def test_ini_then_environment(self):
        ini = self._ini("export_config.ini", "[publish]\nssh = a@b ; comment\ndist = /srv/tiles\n")
        cfg = PR.load_config({"DS_PUBLISH_DIST": "/other"}, ini_path=ini, client_ini="/nope")
        self.assertEqual(cfg["ssh"], "a@b")
        self.assertEqual(cfg["dist"], "/other", "the environment wins")

    def test_http_defaults_to_the_client_tile_url(self):
        client = self._ini("client.ini", '[stream]\ntiles_url="https://tiles.example"\n')
        cfg = PR.load_config({"DS_PUBLISH_SSH": "x@y"}, ini_path="/nope", client_ini=client)
        self.assertEqual(cfg["http"], "https://tiles.example")


class Commands(unittest.TestCase):

    def test_ssh_is_batch_mode_on_the_configured_port(self):
        cmd = PR.ssh_cmd(_cfg(port="2222"), "echo hi")
        self.assertEqual(cmd[:5], ["ssh", "-p", "2222", "-o", "BatchMode=yes"])
        self.assertEqual(cmd[-2:], ["deploy@tiles.example", "sh -c 'echo hi'"],
                         "POSIX sh whatever the login shell (csh on FreeBSD)")

    def test_rsync_when_available_scp_otherwise(self):
        self.assertEqual(PR.copy_cmd(_cfg(), "/a", "w/b", True)[0], "rsync")
        self.assertIn("--partial", PR.copy_cmd(_cfg(), "/a", "w/b", True))
        scp = PR.copy_cmd(_cfg(port="2222"), "/a", "w/b", False)
        self.assertEqual(scp[:4], ["scp", "-q", "-P", "2222"])
        self.assertEqual(scp[-1], "deploy@tiles.example:w/b")

    def test_remote_publish_line_is_quoted(self):
        line = PR.publish_cmd(_cfg(dist="/var/www/my dist"), "ds-publish/x_chunks/t.pack", True)
        self.assertIn("--out '/var/www/my dist'", line)
        self.assertIn("--channel unstable", line)
        self.assertTrue(line.endswith("--compress"))
        self.assertIn(" -u tools/planettech/publish/publish_tiles.py", line,
                      "unbuffered: the server's lines reach publish.log as they come")


class PublishOverSsh(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.chunks = os.path.join(self.dir, "modplanet_chunks")
        os.makedirs(self.chunks)
        self.pack = os.path.join(self.chunks, "terrainmodifier.pack")
        dsmp.write_pack(self.pack, [(1, [(3, b"tile-1-3")]), (64, [(100, b"tile-64-100")])],
                        {"planet_name": "modplanet", "data_version": "cafe0042",
                         "levels": [1, 64], "strings": []})
        self.server = FakeServer(self.dir)
        self.dist = os.path.join(self.dir, "dist")
        os.makedirs(self.dist)
        self.cfg = _cfg(dist=self.dist, python=sys.executable)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_the_pack_is_sent_whole_and_exploded_on_the_server(self):
        rc = PR.publish(self.pack, self.cfg, run=self.server.run, verify=False, rsync=False)
        self.assertEqual(rc, 0)
        root = os.path.join(self.dist, "modplanet.mod", "cafe0042")
        with open(os.path.join(root, "n64", "f0", "f100.bin"), "rb") as fh:
            self.assertEqual(PT.read_tile_blob(fh.read()), b"tile-64-100")
        with open(os.path.join(self.dist, "channels", "unstable.json")) as fh:
            self.assertIn("modplanet.mod", json.load(fh)["planets"])
        sent = [c for c in self.server.calls if c[0] == "scp"]
        self.assertEqual(len(sent), len(PR.REMOTE_CODE) + 1, "the code, then ONE file")
        self.assertTrue(sent[-1][-1].endswith("modplanet_chunks/terrainmodifier.pack"))

    def test_an_unchanged_export_is_not_sent_again(self):
        PR.publish(self.pack, self.cfg, run=self.server.run, verify=False, rsync=False)
        before = len(self.server.calls)
        self.assertEqual(PR.publish(self.pack, self.cfg, run=self.server.run, verify=False), 0)
        self.assertEqual(len(self.server.calls), before, "same version, same target: nothing")
        PR.publish(self.pack, self.cfg, run=self.server.run, verify=False, rsync=False, force=True)
        self.assertGreater(len(self.server.calls), before, "--force republishes")
        other = dict(self.cfg, channel="dev")
        self.assertFalse(PR.already_published(self.pack, other, "cafe0042"),
                         "another channel is another publication")

    def test_the_line_bake_goes_under_its_own_body(self):
        bake = os.path.join(self.chunks, "grade_profiles.pack")
        with open(bake, "wb") as fh:
            fh.write(b"bake" * 50)
        self.assertEqual(PR.publish(bake, self.cfg, run=self.server.run, verify=False,
                                    rsync=False), 0)
        version = PT.file_version(bake)
        with open(os.path.join(self.dist, "modplanet.lines", version, "grade_profiles.pack"),
                  "rb") as fh:
            self.assertEqual(PT.read_tile_blob(fh.read()), b"bake" * 50)
        line = [c for c in self.server.calls if c[0] == "ssh" and "publish_tiles.py" in c[-1]][-1]
        self.assertNotIn("--compress", line[-1], "the bake is zstd already")

    def test_a_regional_line_bake_goes_out_as_tiles_under_the_same_body(self):
        bake = os.path.join(self.chunks, "grade_profiles.pack")
        dsmp.write_pack(bake, [(1, [(0, b"header")]), (16, [(9, b"region-9")])],
                        {"planet_name": "modplanet", "dataset": "lines", "format": 1,
                         "levels": [1, 16], "floor_nside_max": 1})
        self.assertEqual(PR.identity(bake), ("modplanet.lines", PT.file_version(bake)))
        self.assertEqual(PR.publish(bake, self.cfg, run=self.server.run, verify=False,
                                    rsync=False), 0)
        root = os.path.join(self.dist, "modplanet.lines", PT.file_version(bake))
        self.assertTrue(os.path.exists(os.path.join(root, "floor.bin")))
        self.assertTrue(os.path.exists(os.path.join(root, "n16", "f0", "f9.bin")))
        line = [c for c in self.server.calls if c[0] == "ssh" and "publish_tiles.py" in c[-1]][-1]
        self.assertIn("--compress", line[-1], "a region is a raw Dictionary: deflate it")

    def test_a_failing_server_stops_before_recording(self):
        def broken(cmd):
            return (1, "") if cmd[0] == "ssh" and "publish_tiles.py" in cmd[-1] \
                else self.server.run(cmd)
        self.assertEqual(PR.publish(self.pack, self.cfg, run=broken, verify=False, rsync=False), 1)
        self.assertFalse(os.path.exists(os.path.join(self.chunks, PR.TRACE_FILE)))

    def test_only_publishable_files_in_a_chunks_dir(self):
        stray = os.path.join(self.dir, "terrainmodifier.pack")
        shutil.copyfile(self.pack, stray)
        self.assertEqual(PR.publish(stray, self.cfg, run=self.server.run), 1, "no <planet>_chunks")
        other = os.path.join(self.chunks, "manifest.json")
        with open(other, "w") as fh:
            fh.write("{}")
        self.assertEqual(PR.publish(other, self.cfg, run=self.server.run), 1)
        self.assertEqual(self.server.calls, [])

    def test_promote_and_gc_run_the_channel_tool_on_the_server(self):
        PR.publish(self.pack, self.cfg, run=self.server.run, verify=False, rsync=False)
        self.assertEqual(PR.promote(self.cfg, "dev", ["modplanet.mod"], run=self.server.run), 0)
        with open(os.path.join(self.dist, "channels", "dev.json")) as fh:
            self.assertIn("modplanet.mod", json.load(fh)["planets"])
        self.assertEqual(PR.gc(self.cfg, False, run=self.server.run), 0)
        self.assertIn("--dry-run", self.server.calls[-1][-1], "gc measures unless told --yes")

    def test_a_body_published_before_the_channels_survives_gc_and_can_be_adopted(self):
        # Le dist réel : tarsis_3 servi par latest.json, deux versions, aucun canal.
        for version in ("af18", "ee59"):
            root = os.path.join(self.dist, "modplanet", version)
            os.makedirs(os.path.join(root, "n64"))
            open(os.path.join(root, "manifest.json"), "w").write("{}")
        with open(os.path.join(self.dist, "modplanet", "latest.json"), "w") as fh:
            json.dump({"data_version": "ee59", "nside_max": 64}, fh)
        PR.publish(self.pack, self.cfg, run=self.server.run, verify=False, rsync=False)
        self.assertEqual(PR.gc(self.cfg, True, run=self.server.run), 0)
        self.assertTrue(os.path.isdir(os.path.join(self.dist, "modplanet", "af18")))
        self.assertEqual(PR.adopt(self.cfg, ["modplanet"], run=self.server.run), 0)
        with open(os.path.join(self.dist, "channels", "unstable.json")) as fh:
            planets = json.load(fh)["planets"]
        self.assertEqual(planets["modplanet"]["data_version"], "ee59")
        self.assertIn("modplanet.mod", planets, "adoption leaves the other bodies alone")
        PR.gc(self.cfg, True, run=self.server.run)
        self.assertFalse(os.path.isdir(os.path.join(self.dist, "modplanet", "af18")))
        self.assertTrue(os.path.isdir(os.path.join(self.dist, "modplanet", "ee59")))

    def test_channel_commands_send_the_current_code_first(self):
        PR.gc(self.cfg, False, run=self.server.run)
        sent = [c[-1] for c in self.server.calls if c[0] == "scp"]
        self.assertTrue(any(s.endswith("stream_channels.py") for s in sent),
                        "the server runs the repository's gc, safeguards included")


class PartsOnTheServer(unittest.TestCase):
    """Les parts ne sont plus dans git : le pack gardé par le serveur les porte toutes.

    Deux postes, A et B, chacun son dossier d'export, un seul serveur.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.server = FakeServer(self.dir)
        self.dist = os.path.join(self.dir, "dist")
        os.makedirs(self.dist)
        self.cfg = _cfg(dist=self.dist, python=sys.executable)
        self.a = os.path.join(self.dir, "a")
        self.b = os.path.join(self.dir, "b")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _export(self, export_dir, kind="road", width=6.0):
        """Ce que fait un exporteur : réécrire SA part, puis relier."""
        parts = link_modifiers.parts_dir_for("modplanet", export_dir)
        os.makedirs(parts, exist_ok=True)
        table = StringTable.load(parts)
        manifest = {"kind": kind, "max_nside": 64, "min_nside": 1, "planet_name": "modplanet",
                    "radius": 6.0e6, "export_nside": 64, "max_quadtree_nside": 64,
                    "generated_by": "test"}
        if kind == "road":
            rec = dsmp.pack_road(table.intern("road"), table.intern("asphalt"),
                                 table.intern("route"), 2, width, 100.0, 1,
                                 [(1.0, 2.0, 0.0), (1.01, 2.0, 50.0)])
            dsmp.write_part(link_modifiers.part_path("modplanet", "road", export_dir),
                            dsmp.KIND_ROAD, [(64, [(5, dsmp.part_tile(1, rec))])], manifest)
        else:
            rec = dsmp.pack_crater(1.0, 2.0, width, 40.0)
            dsmp.write_part(link_modifiers.part_path("modplanet", "crater", export_dir),
                            dsmp.KIND_CRATER, [(64, [(9, dsmp.part_tile(1, rec))])], manifest)
        table.save(parts)
        return link_modifiers.link("modplanet", export_dir, verbose=False, publish=False)

    def _pack(self, export_dir):
        return os.path.join(export_dir, "modplanet_chunks", "terrainmodifier.pack")

    def _publish(self, export_dir, **kw):
        return PR.publish(self._pack(export_dir), self.cfg, run=self.server.run, verify=False,
                          rsync=False, **kw)

    def _pull(self, export_dir, **kw):
        return PR.pull(self._pack(export_dir), self.cfg, run=self.server.run, rsync=False, **kw)

    def _version(self, export_dir):
        return PR.identity(self._pack(export_dir))[1]

    def test_nothing_on_the_server_keeps_the_local_parts(self):
        self._export(self.a)
        self.assertEqual(self._pull(self.a), "absent")

    def test_another_machine_gets_every_part_back(self):
        self._export(self.a)
        self._export(self.a, kind="crater", width=500.0)
        self.assertEqual(self._publish(self.a), 0)
        self.assertEqual(self._pull(self.b), "reçu")
        with open(self._pack(self.a), "rb") as fa, open(self._pack(self.b), "rb") as fb:
            self.assertEqual(fa.read(), fb.read())
        parts = sorted(os.listdir(link_modifiers.parts_dir_for("modplanet", self.b)))
        self.assertEqual(parts, ["craters.dsmpart", "roads.dsmpart", "strings.json"])
        # B exports its family on top of A's: both survive the relink.
        self._export(self.b, kind="crater", width=800.0)
        self.assertEqual(self._publish(self.b), 0, "B built on the server's version")
        self.assertNotEqual(self._version(self.b), self._version(self.a))

    def test_in_step_or_ahead_nothing_is_fetched(self):
        self._export(self.a)
        self._publish(self.a)
        before = len(self.server.calls)
        self.assertEqual(self._pull(self.a), "à jour")
        self.assertFalse([c for c in self.server.calls[before:] if c[0] == "scp"
                          and c[-2].startswith(HOST)], "nothing downloaded")
        self._export(self.a, width=9.0)       # exported, not published yet
        mine = self._version(self.a)
        self.assertEqual(self._pull(self.a), "à jour", "this machine is ahead")
        self.assertEqual(self._version(self.a), mine, "its export is untouched")

    def test_a_newer_server_version_is_fetched_and_replaces_the_parts(self):
        self._export(self.a)
        self._publish(self.a)
        self._pull(self.b)
        self._export(self.a, width=9.0)
        self._publish(self.a)
        self.assertEqual(self._pull(self.b), "reçu")
        self.assertEqual(self._version(self.b), self._version(self.a))

    def test_both_sides_changed_is_a_conflict_not_an_overwrite(self):
        self._export(self.a)
        self._publish(self.a)
        self._pull(self.b)
        self._export(self.b, width=7.0)       # B's unpublished work
        self._export(self.a, width=9.0)
        self._publish(self.a)                 # A publishes meanwhile
        b_version = self._version(self.b)
        with self.assertRaises(PR.PartsConflict):
            self._pull(self.b)
        self.assertEqual(self._version(self.b), b_version, "B's work is still there")
        self.assertEqual(self._publish(self.b), 1, "and B may not overwrite A's publication")
        self.assertEqual(self._pull(self.b, force=True), "reçu", "unless told to")
        self.assertEqual(self._version(self.b), self._version(self.a))

    def test_an_export_waits_for_no_publication_in_flight(self):
        self._export(self.a)
        import fcntl
        with open(os.path.join(self.a, "modplanet_chunks", ".publish.lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            old = os.environ.get("DS_PUBLISH_SSH")
            os.environ["DS_PUBLISH_SSH"] = HOST
            try:
                self.assertEqual(PR.pull_for_export(self._pack(self.a)), "publication en cours")
            finally:
                if old is None:
                    del os.environ["DS_PUBLISH_SSH"]
                else:
                    os.environ["DS_PUBLISH_SSH"] = old


class ExportHook(unittest.TestCase):

    def test_parts_are_never_pulled_outside_the_export_directory(self):
        tmp = tempfile.mkdtemp()
        try:
            self.assertIsNone(link_modifiers.pull_parts("x", tmp))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_a_pack_outside_the_export_directory_is_never_published(self):
        tmp = tempfile.mkdtemp()
        try:
            self.assertIsNone(link_modifiers.auto_publish(
                os.path.join(tmp, "x_chunks", "terrainmodifier.pack")))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
