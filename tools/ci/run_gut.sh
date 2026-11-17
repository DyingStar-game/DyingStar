#!/bin/bash
#
# Runs GUT headless and judges the run with tools/ci/gut_report.py, not with the engine's exit code:
# the engine can crash while it shuts down after a perfect run, and GUT leaves a test script that does
# not parse out of the run without counting it. See gut_report.py for what fails the run.
#
# Usage: tools/ci/run_gut.sh <output dir> [GUT options...]
#   e.g. tools/ci/run_gut.sh .godot/gut -gdir=res://test/unit
#   GODOT           the Godot binary (default: godot)
#   GITHUB_STEP_SUMMARY, when set, receives the Markdown summary.

set -uo pipefail

cd "$(dirname "$0")/../.."
out="${1:?usage: run_gut.sh <output dir> [GUT options...]}"
shift
mkdir -p "$out"
xml="$out/gut.xml"
log="$out/gut.log"
rm -f "$xml" "$log"

"${GODOT:-godot}" --headless --path . -s addons/gut/gut_cmdln.gd -gexit \
    -gjunit_xml_file="$(realpath "$out")/gut.xml" "$@" 2>&1 | tee "$log"
engine=${PIPESTATUS[0]}
echo "engine exit code: $engine"

python3 tools/ci/gut_report.py --xml "$xml" --log "$log" ${GITHUB_STEP_SUMMARY:+--summary "$GITHUB_STEP_SUMMARY"}
