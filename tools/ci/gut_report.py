#!/usr/bin/env python3
"""Judges a GUT run from its JUnit XML and its console output, not from the engine's exit code.

The engine's exit code alone lies both ways: a crash while it shuts down (after GUT has written its
report) turns a green run red, and a test script that does not parse is skipped by GUT without being
counted anywhere, so a run can be "all passing" while whole files never ran.

Fails (exit 1) when:
  - the XML is missing or unreadable (the engine died during the run);
  - any test failed;
  - the console output shows a test script that failed to load;
  - no test ran at all.

Writes a Markdown summary (failures, scripts not loaded, slowest scripts) to --summary, which the
workflow points at $GITHUB_STEP_SUMMARY.

Usage: gut_report.py --xml results.xml --log gut.log [--summary out.md]
Python 3 standard library only.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET

# GUT's collector loads every test script with load(); a parse or compile error is reported by the
# engine with this line and the script is then silently left out of the run.
NOT_LOADED = re.compile(r'Failed to load script "(res://test/[^"]+)"')
SLOWEST = 15


def read_results(xml_path):
    """Returns (tests, failures, skipped, failed_cases, script_times) or None when unreadable."""
    try:
        root = ET.parse(xml_path).getroot()
    except (OSError, ET.ParseError) as err:
        print(f"::error::no readable GUT report at {xml_path}: {err}")
        return None
    tests = skipped = 0
    failed = []
    times = []
    for suite in root.iter("testsuite"):
        tests += int(suite.get("tests", 0))
        skipped += int(suite.get("skipped", 0))
        times.append((float(suite.get("time", 0.0)), suite.get("name", "?")))
        for case in suite.iter("testcase"):
            failure = case.find("failure")
            if failure is not None:
                # GUT puts the assertion text in the body; its message attribute is always "failed".
                message = (failure.text or failure.get("message") or "").strip()
                failed.append((suite.get("name", "?"), case.get("name", "?"), message))
    # Failing TESTS: a suite's "failures" attribute counts failed asserts.
    return tests, len(failed), skipped, failed, times


def read_not_loaded(log_path):
    try:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            return sorted(set(NOT_LOADED.findall(f.read())))
    except OSError as err:
        print(f"::error::no GUT console output at {log_path}: {err}")
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--xml", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--summary")
    args = parser.parse_args()

    results = read_results(args.xml)
    not_loaded = read_not_loaded(args.log)
    lines = ["## GUT"]
    ok = results is not None and not_loaded is not None
    if results is None:
        lines.append("**No report**: the engine stopped before GUT wrote its results (crash?).")
    else:
        tests, failures, skipped, failed, times = results
        lines.append(f"{tests} tests, **{failures} failing**, {skipped} pending/risky.")
        if tests == 0:
            print("::error::GUT ran no test")
            lines.append("**No test ran.**")
            ok = False
        if failures:
            ok = False
            lines += ["", "### Failing", "", "| Script | Test | Message |", "|---|---|---|"]
            for script, case, message in failed:
                first = " ".join(message.split())[:200]
                first = first.replace("|", "\\|")
                lines.append(f"| `{script}` | `{case}` | {first} |")
                print(f"::error title=GUT {script}::{case}: {first}")
        times.sort(reverse=True)
        lines += ["", f"### Slowest {SLOWEST} scripts (time in their tests; before_all is not counted)", "",
                  "| s | Script |", "|---:|---|"]
        lines += [f"| {t:.1f} | `{name}` |" for t, name in times[:SLOWEST]]
    if not_loaded:
        ok = False
        lines += ["", "### Test scripts that did not load (never ran)", ""]
        lines += [f"- `{path}`" for path in not_loaded]
        for path in not_loaded:
            print(f"::error title=GUT script not loaded::{path} failed to load: none of its tests ran")
    lines += ["", "**Verdict: " + ("passed" if ok else "FAILED") + "**", ""]

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write("\n".join(lines))
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
