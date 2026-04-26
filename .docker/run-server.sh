#!/usr/bin/env bash
# Entrypoint wrapper for the DyingStar Godot dedicated server.
#
# Runs the server under gdb so any unmanaged crash (SIGSEGV/139) prints a
# full backtrace of all threads to stdout, instead of the container dying
# silently with just an exit code.
#
# Set DEBUG_GDB=0 to bypass gdb (lower overhead, recommended for production).
# Args passed to this script are forwarded to the server binary.

set -u

cd /app

BIN=./dyingstar_server.x86_64

# Allow native core dumps when permitted by the host.
ulimit -c unlimited 2>/dev/null || true

if [[ "${DEBUG_GDB:-1}" == "1" ]] && command -v gdb >/dev/null 2>&1; then
    echo "[run-server] Launching under gdb (set DEBUG_GDB=0 to disable)."
    exec gdb \
        -batch \
        -ex "set pagination off" \
        -ex "handle SIGPIPE nostop noprint pass" \
        -ex "run" \
        -ex "thread apply all bt full" \
        -ex "quit" \
        --args "$BIN" --verbose "$@"
else
    echo "[run-server] Launching server directly (no gdb)."
    exec "$BIN" --verbose "$@"
fi
