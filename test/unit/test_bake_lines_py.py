"""The QGIS plugin's « Recuire les profils des lignes » (tools/planettech/qgis/bake_lines.py): the
bake's command line and the progress read from its log. No QGIS, no Godot:
`python3 test/unit/test_bake_lines_py.py`.

What it guards: a bake that would publish itself from the checkout (the plugin publishes it from
its export folder, where « Journal de publication » looks), and a progress bar stuck at 0 or
going backwards on the bake's real log lines.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                                "..", "tools", "planettech", "qgis")))

import bake_lines  # noqa: E402
import channels  # noqa: E402

LOG = """[GradeBake] === tarsis_3 ===
[GradeBake] tarsis_3: 4 line(s), 9133 export tile(s) under them (walk 80123 ms)
[GradeBake] tarsis_3: 9133/9133 tile(s) present after download (30 s)
[GradeBake] tarsis_3: 6400 published ancestor(s) of pruned tiles fetched (60 s)
[GradeBake]   fid 2 stations: 10/40 slice(s) — 60 s, ~180 s left
[GradeBake] tarsis_3 fid 0 (highway): 2246 km, 11230 knot(s), 812 segment(s) — 40 s
[GradeBake] tarsis_3 fid 1 (road): 12 km, 60 knot(s), 9 segment(s) — 0 s
[GradeBake] tarsis_3 fid 3 (road): 8 km, 40 knot(s), 3 segment(s) — 0 s
[GradeBake] tarsis_3 fid 2 (railway): 42430 km, 212150 knot(s), 4000 segment(s) — 267 s
[GradeBake] tarsis_3: 14111 chasm crossing(s) found in 40 s
[GradeBake] tarsis_3: 12342 deck plan(s) over 900 span tile(s) in 35 s
[GradeBake] tarsis_3: res://x/grade_profiles.pack — 4/4 line(s) baked, crossings baked, 7.2 MB, 561 s in all
[GradeBake] done — 1 planet(s), 0 failed"""


class Progress(unittest.TestCase):

    def test_rises_to_one_and_never_back(self):
        state, reached, seen = {}, 0.0, []
        for line in LOG.splitlines():
            reached = max(reached, bake_lines.progress_of(line, state))
            seen.append(reached)
        self.assertEqual(seen[0], 0.0)
        self.assertEqual(state["lines"], 4)
        self.assertEqual(seen, sorted(seen))
        self.assertAlmostEqual(seen[-1], 1.0)
        # Each line profiled moves it on, between the ancestors and the crossings.
        lines_part = seen[5:9]
        self.assertEqual(len(set(lines_part)), 4)
        self.assertAlmostEqual(lines_part[-1], bake_lines._LINES_TO)

    def test_the_slice_lines_are_not_line_profiles(self):
        state = {"lines": 4}
        self.assertEqual(bake_lines.progress_of(
            "[GradeBake]   fid 2 stations: 10/40 slice(s) — 60 s, ~180 s left", state), 0.0)
        self.assertNotIn("done", state)


class Command(unittest.TestCase):

    def test_reads_the_channel_and_leaves_the_publication_to_the_plugin(self):
        os.environ["GODOT_BIN"] = sys.executable          # any existing file
        cmd = bake_lines.command("tarsis_3", "unstable", "/tmp/x.log")
        self.assertIn("res://tools/bake_grade_profiles.tscn", cmd)
        self.assertIn("--planet=tarsis_3", cmd)
        self.assertIn("--tile-channel=unstable", cmd)
        self.assertIn("--log=/tmp/x.log", cmd)
        self.assertIn("--no-publish", cmd)
        self.assertGreater(cmd.index("--no-publish"), cmd.index("--"))


class LinesVerdict(unittest.TestCase):
    """« Promouvoir… »: are the line profiles a channel serves the ones baked for its modifiers?"""

    def setUp(self):
        import json
        import tempfile
        self.dir = tempfile.mkdtemp(prefix="bake_record_")
        with open(os.path.join(self.dir, "grade_profiles.pack"), "wb") as fh:
            fh.write(b"bake")
        channels.write_bake_record(self.dir, "mod1", "unstable")
        with open(os.path.join(self.dir, ".published.json"), "w") as fh:
            json.dump({"grade_profiles.pack": {"version": "lines1"}}, fh)

    def test_baked_for_the_served_pack(self):
        served = {"p.mod": "mod1", "p.lines": "lines1"}
        self.assertIs(channels.lines_verdict(self.dir, "p", served), True)

    def test_the_pack_moved_on_since_the_bake(self):
        served = {"p.mod": "mod2", "p.lines": "lines1"}
        self.assertIs(channels.lines_verdict(self.dir, "p", served), False)

    def test_profiles_published_from_elsewhere_are_unknown(self):
        served = {"p.mod": "mod1", "p.lines": "lines0"}
        self.assertIsNone(channels.lines_verdict(self.dir, "p", served))

    def test_a_local_rebake_not_published_is_unknown(self):
        with open(os.path.join(self.dir, "grade_profiles.pack"), "wb") as fh:
            fh.write(b"rebaked")
        served = {"p.mod": "mod1", "p.lines": "lines1"}
        self.assertIsNone(channels.lines_verdict(self.dir, "p", served))

    def test_channel_order(self):
        self.assertEqual(channels.previous("dev"), "unstable")
        self.assertEqual(channels.previous("prod"), "preprod")
        self.assertIsNone(channels.previous("unstable"))


if __name__ == "__main__":
    unittest.main()
