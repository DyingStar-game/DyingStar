"""The plugin's own steps (runner contract: prepare on the main thread, work anywhere):
relinking the modifier pack and the publication commands of publish_remote.py."""
import os
import shutil
import subprocess
import sys


def _planet():
    import ds_project
    return ds_project.planet()


def link():
    """Rebuild terrainmodifier.pack from every part present (and publish it, when configured)."""
    import link_modifiers
    planet = _planet().name
    export_dir = link_modifiers.resolve_export_dir()
    return lambda: link_modifiers.link(planet, export_dir)


def _publish_script():
    import link_modifiers
    root = link_modifiers.repo_root()
    if root is None:
        raise RuntimeError("DyingStar checkout not found: set it in the plugin settings")
    return os.path.join(root, "tools", "planettech", "publish", "publish_remote.py")


def _python():
    """A Python 3 interpreter for the publication script — QGIS's sys.executable may be qgis."""
    return shutil.which("python3") or shutil.which("python") or sys.executable


def _command(args):
    """publish_remote.py [args], its output streamed into the job's log."""
    script = _publish_script()

    def work():
        cmd = [_python(), script, *args]
        print("  $ " + " ".join(cmd))
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                cwd=os.path.dirname(script), env=dict(os.environ))
        for line in proc.stdout:
            print("  " + line.rstrip("\n"))
        code = proc.wait()
        if code != 0:
            raise RuntimeError(f"publish_remote.py {' '.join(args)} exited with {code}")
    return work


def check():
    """ssh, python3 on the server and write access to dist."""
    return _command(["--check"])


def pull(force=False):
    """parts/ at the server's version (force: overwrite the local parts)."""
    return _command(["--pull", _planet().name] + (["--force"] if force else []))


def promote(channel, bodies):
    """Move [bodies] (tarsis_3, tarsis_3.mod, tarsis_3.lines…) one step up to [channel]."""
    if not bodies:
        return None
    return _command(["--promote", channel, "--planet", *bodies])
