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

# stdout is a pipe here, so the C runtime block-buffers it: print() lines reached Loki in 8 KiB
# bursts stamped with the flush instant, minutes after the fact — and the last ones never, when
# the process died or was still running (2026-09-20: the three minutes before a player fell through
# tarsis_3 were still sitting in the buffer). Line-buffer it so a print is a log line NOW, like the
# ERROR/WARNING lines on stderr already are. stdbuf sets the mode through LD_PRELOAD, which the
# gdb launch below inherits; the exported Godot binary links libc dynamically, so it applies.
if command -v stdbuf >/dev/null 2>&1; then
    STDBUF=(stdbuf -oL)
else
    echo "[run-server] stdbuf not found: stdout stays block-buffered (log lines arrive late)."
    STDBUF=()
fi

# Allow native core dumps when permitted by the host.
ulimit -c unlimited 2>/dev/null || true

if [[ "${DEBUG_GDB:-1}" == "1" ]] && command -v gdb >/dev/null 2>&1; then
    echo "[run-server] Launching under gdb (set DEBUG_GDB=0 to disable)."
    exec "${STDBUF[@]}" gdb \
        -batch \
        -ex "set pagination off" \
        -ex "handle SIGPIPE nostop noprint pass" \
        -ex "run" \
        -ex "thread apply all bt full" \
        -ex "quit" \
        --args "$BIN" --verbose "$@"
else
    echo "[run-server] Launching server directly (no gdb)."
    exec "${STDBUF[@]}" "$BIN" --verbose "$@"
fi
