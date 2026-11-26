"""The QGIS plugin's publication journal (tools/planettech/qgis/ds_plugin/publish_log.py): how it
reads <planet>_chunks/publish.log. No QGIS needed: `python3 test/unit/test_publish_log_py.py`.

What it guards: a finished publication shown as still running (or the reverse), a failure taken
for a success, and a publication that has just started reported as stopped.
"""
import fcntl
import importlib.util
import os
import tempfile
import time
import unittest

_PATH = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                     "tools", "planettech", "qgis", "ds_plugin", "publish_log.py"))
_spec = importlib.util.spec_from_file_location("ds_publish_log", _PATH)
PL = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(PL)

OK = """
--- 2026-11-26T01:58:00 /x/tarsis_3_chunks/terrainmodifier.pack
== terrainmodifier.pack → root@host:/dist/ (corps tarsis_3.mod, version 1e472bfcf1d0ae05, canal unstable)
  envoi de terrainmodifier.pack (350.8 Mo, rsync)
  413 tuiles vérifiées, 131 absences confirmées en 404, 0 désaccord(s)
== publié : tarsis_3.mod 1e472bfcf1d0ae05 sur le canal unstable
   promotion : python3 tools/planettech/publish/publish_remote.py --promote dev --planet tarsis_3.mod
"""
STARTED = """
--- 2026-11-26T08:34:37 /x/tarsis_3_chunks/terrainmodifier.pack
== terrainmodifier.pack → root@host:/dist/ (corps tarsis_3.mod, version 9, canal unstable)
  éclatement sur le serveur
"""
FAILED = """
--- 2026-11-26T00:10:00 /x/tarsis_3_chunks/terrainmodifier.pack
  éclatement sur le serveur
    sh: pythn3.12: not found
ERREUR : publish_tiles.py a échoué sur le serveur
"""
NOTHING = """
--- 2026-11-26T09:00:00 /x/tarsis_3_chunks/grade_profiles.pack
grade_profiles.pack b4f3 déjà publié sur unstable (root@host) — rien à faire (--force pour republier)
"""


class Blocks(unittest.TestCase):

    def test_one_block_per_publication(self):
        bl = PL.blocks(OK + STARTED)
        self.assertEqual(len(bl), 2)
        self.assertTrue(bl[1][0].startswith("--- 2026-11-26T08:34:37"))
        self.assertIn("éclatement", bl[1][1])

    def test_conclusions(self):
        self.assertEqual(PL.block_state(PL.blocks(OK)[0][1], False), PL.DONE)
        self.assertEqual(PL.block_state(PL.blocks(FAILED)[0][1], True), PL.FAILED)
        self.assertEqual(PL.block_state(PL.blocks(NOTHING)[0][1], False), PL.NOTHING)
        body = PL.blocks(STARTED)[0][1]
        self.assertEqual(PL.block_state(body, True), PL.RUNNING)
        self.assertEqual(PL.block_state(body, False), PL.STOPPED)

    def test_published_line(self):
        self.assertEqual(PL.published_line(PL.blocks(OK)[0][1]),
                         "publié : tarsis_3.mod 1e472bfcf1d0ae05 sur le canal unstable")


class Folder(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="publish_log_")
        self.log = os.path.join(self.dir, PL.LOG_FILE)

    def _write(self, text, age_s=0.0):
        with open(self.log, "w", encoding="utf-8") as fh:
            fh.write(text)
        t = time.time() - age_s
        os.utime(self.log, (t, t))

    def test_no_journal(self):
        self.assertEqual(PL.status(self.dir)[0], None)

    def test_the_lock_says_running(self):
        self._write(OK + STARTED, age_s=600.0)
        self.assertEqual(PL.status(self.dir)[0], PL.STOPPED, "no lock, old journal")
        with open(os.path.join(self.dir, PL.LOCK_FILE), "w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)     # what publish_remote._locked holds
            self.assertEqual(PL.status(self.dir)[0], PL.RUNNING)
            fcntl.flock(fh, fcntl.LOCK_UN)
        self.assertEqual(PL.status(self.dir)[0], PL.STOPPED)

    def test_a_fresh_header_is_starting_not_stopped(self):
        self._write(OK + STARTED, age_s=1.0)
        self.assertEqual(PL.status(self.dir)[0], PL.RUNNING)

    def test_tail_starts_on_a_whole_line(self):
        self._write("x" * 100 + "\n" + OK)
        tail = PL.read_tail(self.log, limit=len(OK.encode("utf-8")) + 10)
        self.assertTrue(tail.startswith("\n--- ") or tail.startswith("--- "), tail[:20])
        self.assertEqual(PL.status(self.dir)[0], PL.DONE)


if __name__ == "__main__":
    unittest.main()
