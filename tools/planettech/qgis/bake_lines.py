"""Re-bake the planet's line profiles (railways, graded roads, chasm bridges) with Godot headless —
DyingStar ▸ Publication ▸ Recuire les profils des lignes.

The bake (tools/bake_grade_profiles.gd) is keyed on the published modifier pack: every export
of the pack makes it stale, and the game then profiles every line at run time, building chunks
before their line's profile lands (roads cut off at a chunk edge, holes along the cuttings). It
reads the tile service on the publication channel (unstable: where the export just went) and
writes grade_profiles.pack in the checkout's <planet>_chunks; the plugin copies it into its export
folder and publishes it from there (body <planet>.lines), followed in « Journal de publication »
like an export's.
"""
import os
import shutil
import subprocess
import sys
import time

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import channels        # noqa: E402
import ds_project      # noqa: E402
import link_modifiers  # noqa: E402

BAKE_FILE = "grade_profiles.pack"

#: Set by the plugin's runner: callable(fraction); raises to cancel.
PROGRESS = None

#: The bake's phases, as its log names them, and the share of the run reached once seen
#: (tarsis_3, 2026-09: walk 80 s, tiles 30 s, ancestors 60 s, profiles ~270 s, bridges ~75 s).
#: Between "ancestors" and "crossings", each line's "fid N (…): … km" line moves it on.
_PHASES = [("export tile(s) under them", 0.10), ("present after download", 0.18),
           ("published ancestor(s)", 0.25), ("chasm crossing(s) found", 0.80),
           ("deck plan(s)", 0.92), ("line(s) baked", 0.97), ("done —", 1.0)]
_LINES_FROM, _LINES_TO = 0.25, 0.80


def _progress(f):
    if PROGRESS is not None:
        PROGRESS(f)


def command(planet, channel, log):
    import zone_terrain
    repo = link_modifiers.repo_root()
    if repo is None:
        raise RuntimeError("DyingStar checkout not found: set it in the plugin settings")
    if not os.path.exists(os.path.join(repo, "tools", "bake_grade_profiles.tscn")):
        raise RuntimeError(f"{repo} has no tools/bake_grade_profiles.tscn")
    return [zone_terrain.godot_binary(), "--headless", "--path", repo,
            "res://tools/bake_grade_profiles.tscn", "--", f"--planet={planet}",
            f"--tile-channel={channel}", f"--log={log}", "--no-publish"]


def prepare(channel=None):
    """Main thread: the planet of the open project, the channel, the command."""
    planet = ds_project.planet().name
    channel = channel or os.environ.get("DS_PUBLISH_CHANNEL", "").strip() or "unstable"
    out_dir = link_modifiers.chunks_dir_for(planet, link_modifiers.resolve_export_dir())
    os.makedirs(out_dir, exist_ok=True)
    log = os.path.join(out_dir, "grade_bake.log")
    cmd = command(planet, channel, log)
    print("=" * 64)
    print(f"  Line profiles of {planet} — tiles of channel {channel}")
    print("  $ " + " ".join(cmd))

    def work():
        # The pack the bake reads: recorded beside the bake, so « Promouvoir… » can tell whether
        # the profiles on a channel go with its modifiers.
        mod = _mod_on(channel, planet)
        print(f"  modifiers on {channel}: {planet}.mod {mod or '?'}")
        if os.path.exists(log):
            os.remove(log)
        started = time.time()
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        seen, reached, state = 0, 0.0, {}
        try:
            while proc.poll() is None:
                time.sleep(0.5)
                seen, reached = _relay(log, seen, reached, state)
            seen, reached = _relay(log, seen, reached, state)
        except BaseException:
            proc.kill()
            proc.wait()
            raise
        err = proc.stderr.read() if proc.stderr else ""
        if proc.returncode != 0:
            tail = "\n".join(line for line in err.splitlines()[-15:] if line.strip())
            raise RuntimeError(f"bake_grade_profiles failed (exit {proc.returncode}); see {log}"
                               f"\n{tail}")
        # Exit 0 = a complete bake (lines and crossings) or nothing to bake: an incomplete one
        # makes the tool fail, and stays local.
        if "nothing to bake" in _text(log):
            print(f"  · {planet}: no profiled line and no chasm crossing — nothing to bake")
            return None
        baked = os.path.join(link_modifiers.repo_root(), "assets", "qgis", "export",
                             f"{planet}_chunks", BAKE_FILE)
        if not os.path.exists(baked) or os.path.getmtime(baked) < started - 1.0:
            raise RuntimeError(f"the bake did not write {baked}; see {log}")
        target = os.path.join(out_dir, BAKE_FILE)
        if not (os.path.exists(target) and os.path.samefile(baked, target)):
            shutil.copyfile(baked, target)
            print(f"  → {target}")
        after = _mod_on(channel, planet)
        if mod and after and after != mod:
            print(f"  ! {planet}.mod changed on {channel} during the bake ({mod} → {after}): "
                  f"not published — bake again")
            return None
        if mod:
            channels.write_bake_record(out_dir, mod, channel)
        if link_modifiers.auto_publish(target):
            print(f"  ✓ {planet}: line profiles baked, being published (« Journal de "
                  f"publication »); then promote {planet}.lines with the modifier pack")
        else:
            print(f"  ✓ {planet}: line profiles baked — no publication target configured")
    return work


def _mod_on(channel, planet):
    try:
        return channels.read(channel).get(f"{planet}.mod", "")
    except Exception as exc:  # noqa: BLE001 — the bake itself does not need it
        print(f"  ! channel {channel} unreadable ({exc}): the bake's pack is not recorded")
        return ""


def _text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _relay(path, seen, reached, state=None):
    """Print the bake's new log lines; its phases become the task's progress."""
    state = {} if state is None else state
    _progress(reached)   # also the cancellation point
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return seen, reached
    for line in lines[seen:]:
        print("  " + line)
        reached = max(reached, progress_of(line, state))
    _progress(reached)
    return len(lines), reached


def progress_of(line, state):
    """The share of the bake done once [line] is logged (0 when it says nothing)."""
    for key, share in _PHASES:
        if key in line:
            if key == "export tile(s) under them":
                try:
                    state["lines"] = int(line.split(": ", 1)[1].split(" line(s)")[0])
                except (IndexError, ValueError):
                    pass
            return share
    if " fid " in line and " km, " in line and state.get("lines"):
        state["done"] = state.get("done", 0) + 1
        return _LINES_FROM + (_LINES_TO - _LINES_FROM) * min(1.0, state["done"] / state["lines"])
    return 0.0
