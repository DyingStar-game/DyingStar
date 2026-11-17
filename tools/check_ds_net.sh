#!/bin/bash
#
# Fails unless addons/ds_net/bin holds both network extension libraries built from the commit pinned
# in addons/ds_net/HORIZONSERVER_REV (bin/BUILT_FROM, written by tools/build_ds_net.sh). Run by the
# tests and the client build; .github/workflows/ds-net.yml rebuilds the libraries when the pin moves.

set -euo pipefail

cd "$(dirname "$0")/.."
rev="$(cat addons/ds_net/HORIZONSERVER_REV)"
built="$(cat addons/ds_net/bin/BUILT_FROM 2>/dev/null || true)"
for lib in libds_godot_net.linux.x86_64.so ds_godot_net.windows.x86_64.dll; do
    if [ ! -f "addons/ds_net/bin/$lib" ]; then
        echo "::error file=addons/ds_net/HORIZONSERVER_REV::addons/ds_net/bin/$lib is missing (ds-net.yml builds it on a pull request that moves the pin)."
        exit 1
    fi
done
if [ "$built" != "$rev" ]; then
    echo "::error file=addons/ds_net/HORIZONSERVER_REV::the network extension is built from '${built:-nothing}', the pin is $rev (ds-net.yml rebuilds it on the pull request)."
    exit 1
fi
echo "Network extension built from $rev."
