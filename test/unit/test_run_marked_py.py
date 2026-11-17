#!/usr/bin/env python3
"""
Unit tests for tools/ci/run_marked.py -- a test passes on its result line, not its exit code.

Pure stdlib, no Godot: the "engine" is a Python one-liner.

    python3 test/unit/test_run_marked_py.py
"""
import io
import os
import sys
import unittest
from contextlib import redirect_stdout

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "ci"))

import run_marked  # noqa: E402


def _engine(text: str, code: int) -> list[str]:
    return [sys.executable, "-c",
            f"import sys; sys.stdout.buffer.write({text.encode('utf-8')!r}); sys.exit({code})"]


class TestRunMarked(unittest.TestCase):
    def _run(self, pass_re: str, text: str, code: int) -> int:
        out = io.TextIOWrapper(io.BytesIO(), encoding="cp1252")  # a Windows console
        with redirect_stdout(out):
            return run_marked.main(["--pass", pass_re, "--"] + _engine(text, code))

    def test_the_result_line_passes_whatever_the_exit_code(self) -> None:
        self.assertEqual(self._run("LAVA_WEEK pass=true", "x\nLAVA_WEEK pass=true\n", 1), 0)

    def test_no_result_line_fails_even_on_exit_0(self) -> None:
        self.assertEqual(self._run("LAVA_WEEK pass=true", "LAVA_WEEK pass=false\n", 0), 1)

    def test_characters_a_windows_console_cannot_write_do_not_crash_it(self) -> None:
        self.assertEqual(self._run("pass=true", "caract�re\npass=true\n", 0), 0)


if __name__ == "__main__":
    unittest.main()
