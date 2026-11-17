#!/usr/bin/env python3
"""Runs a headless Godot test and judges it from the result line it prints, not from its exit code.

The engine's exit code is not the test's: a test that printed its passing result and called
quit(0) still exits 1 now and then on Windows (and aborts at shutdown on Linux), so a passing run
failed CI at random. Each lava / volcano test prints one result line; that line decides.

Usage: run_marked.py --pass '<regex>' -- <command…>
Exit 0 when a line of the command's output matches the regex, 1 otherwise (the output is echoed
as it comes). The engine's exit code is printed, for the record.
Python 3 standard library only.
"""

import argparse
import re
import subprocess
import sys


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pass", dest="pass_re", required=True,
                        help="regex a line of the output must match for the test to pass")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    # Echoed as it comes, whatever the console's code page (cp1252 on Windows cannot write the
    # replacement characters Godot prints).
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no command after --")
    marker = re.compile(args.pass_re)
    passed = False
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace")
    for line in proc.stdout:
        sys.stdout.write(line)
        if marker.search(line):
            passed = True
    code = proc.wait()
    sys.stdout.flush()
    print(f"engine exit code: {code}; result line {'found' if passed else 'NOT found'} ({args.pass_re})")
    if not passed:
        print(f"::error::no line matched {args.pass_re}: the test did not pass")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
