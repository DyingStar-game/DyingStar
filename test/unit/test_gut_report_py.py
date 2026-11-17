#!/usr/bin/env python3
"""
Unit tests for tools/ci/gut_report.py -- what turns a GUT run red in CI.

Pure stdlib, no Godot, so this runs anywhere and in CI next to the script itself:

    python3 test/unit/test_gut_report_py.py

The cases are the ways a run used to pass while broken: failures behind a crash at shutdown, a test
script GUT skipped because it did not parse, no report at all.
"""
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "ci"))

import gut_report  # noqa: E402

PASSING = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="GutTests" failures="0" tests="2">
  <testsuite name="test/unit/test_a.gd" tests="2" failures="0" skipped="1" time="1.5">
    <testcase name="test_one" assertions="1" status="pass" classname="test/unit/test_a.gd" time="1.0"></testcase>
    <testcase name="test_two" assertions="0" status="pending" classname="test/unit/test_a.gd" time="0.5">
      <skipped message="pending"><![CDATA[no data]]></skipped>
    </testcase>
  </testsuite>
</testsuites>"""

FAILING = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="GutTests" failures="1" tests="2">
  <testsuite name="test/unit/test_b.gd" tests="2" failures="1" skipped="0" time="3.0">
    <testcase name="test_ok" assertions="1" status="pass" classname="test/unit/test_b.gd" time="1.0"></testcase>
    <testcase name="test_broken" assertions="1" status="fail" classname="test/unit/test_b.gd" time="2.0">
      <failure message="failed"><![CDATA[[1] expected to equal [2]]]></failure>
    </testcase>
  </testsuite>
</testsuites>"""

EMPTY = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="GutTests" failures="0" tests="0">
</testsuites>"""

NOT_LOADED_LOG = """SCRIPT ERROR: Parse Error: Expected indented block after function declaration.
ERROR: Failed to load script "res://test/unit/test_player_location.gd" with error "Parse error".
ERROR: Failed to load script "res://scenes/whatever.gd" with error "Parse error".
"""


class TestVerdict(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.dir = Path(self._dir.name)

    def tearDown(self) -> None:
        self._dir.cleanup()

    def _run(self, xml: str | None, log: str = "") -> tuple[int, str, str]:
        xml_path = self.dir / "gut.xml"
        if xml is not None:
            xml_path.write_text(xml, encoding="utf-8")
        log_path = self.dir / "gut.log"
        log_path.write_text(log, encoding="utf-8")
        summary = self.dir / "summary.md"
        sys.argv = ["gut_report.py", "--xml", str(xml_path), "--log", str(log_path),
                    "--summary", str(summary)]
        out = io.StringIO()
        with redirect_stdout(out):
            code = gut_report.main()
        return code, out.getvalue(), summary.read_text(encoding="utf-8")

    def test_a_clean_run_passes(self) -> None:
        code, _out, summary = self._run(PASSING)
        self.assertEqual(code, 0)
        self.assertIn("2 tests, **0 failing**, 1 pending", summary)
        self.assertIn("Verdict: passed", summary)

    def test_a_failing_test_fails_the_run(self) -> None:
        code, out, summary = self._run(FAILING)
        self.assertEqual(code, 1)
        self.assertIn("`test_broken`", summary, "the failing test is named")
        self.assertIn("[1] expected to equal [2]", summary, "with the assertion, not GUT's bare \"failed\"")
        self.assertIn("2 tests, **1 failing**", summary)
        self.assertIn("::error", out, "and annotated in the workflow")

    def test_a_script_that_did_not_load_fails_a_green_run(self) -> None:
        code, _out, summary = self._run(PASSING, NOT_LOADED_LOG)
        self.assertEqual(code, 1)
        self.assertIn("res://test/unit/test_player_location.gd", summary)
        self.assertNotIn("res://scenes/whatever.gd", summary, "only test scripts count")

    def test_no_report_fails(self) -> None:
        code, _out, summary = self._run(None)
        self.assertEqual(code, 1)
        self.assertIn("No report", summary)

    def test_a_run_with_no_test_fails(self) -> None:
        code, _out, _summary = self._run(EMPTY)
        self.assertEqual(code, 1)

    def test_the_slowest_scripts_are_listed(self) -> None:
        _code, _out, summary = self._run(FAILING)
        self.assertIn("| 3.0 | `test/unit/test_b.gd` |", summary)


if __name__ == "__main__":
    unittest.main()
