#!/bin/bash
#
# Builds the client's network extension (addons/ds_net) from horizonserver/godot_net and copies
# the libraries into addons/ds_net/bin.
#
# Usage: tools/build_ds_net.sh [linux|windows|all]
#   HORIZONSERVER_DIR  the horizonserver checkout (default: ../horizonserver), at the commit of
#                      addons/ds_net/HORIZONSERVER_REV or newer
#   GODOT_BIN          the project's Godot binary (4.7, precision=double; default: godot)
#
# Needs cargo; Windows also the x86_64-pc-windows-gnu target and MinGW-w64.

set -euo pipefail

cd "$(dirname "$0")/.."
horizonserver="${HORIZONSERVER_DIR:-../horizonserver}"
if [ ! -x "$horizonserver/godot_net/build.sh" ]; then
    echo "no godot_net/build.sh in $horizonserver (set HORIZONSERVER_DIR)" >&2
    exit 1
fi
expected="$(cat addons/ds_net/HORIZONSERVER_REV)"
actual="$(git -C "$horizonserver" rev-parse HEAD)"
if [ "$expected" != "$actual" ]; then
    echo "note: $horizonserver is at $actual, addons/ds_net/HORIZONSERVER_REV says $expected" >&2
fi
"$horizonserver/godot_net/build.sh" "${GODOT_BIN:-godot}" addons/ds_net/bin "${1:-all}"
