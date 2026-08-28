"""Regenerating the Asset Browser library.

Single responsibility: run build_asset_library.py in a separate Blender
process and report what happened. Knows nothing about panels or materials.

Why a subprocess rather than doing it in-session: the build script starts from
an empty file and reconstructs the whole library, which would wipe the artist's
open scene. Running it separately keeps one single code path producing the
.blend, so the library is always the output of the same script whether it was
triggered from the addon or from the command line.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import bpy

from . import preferences

BUILD_SCRIPT_RELATIVE_PATH = ("tools", "build_asset_library.py")

# The build is short, but a broken script must not hang Blender for ever.
BUILD_TIMEOUT_SECONDS = 300


class BuildError(RuntimeError):
    """Raised when the library could not be regenerated."""


def build_script_path() -> Path | None:
    root = preferences.resolve_root()
    if root is None:
        return None

    path = root.joinpath(*BUILD_SCRIPT_RELATIVE_PATH)
    return path if path.is_file() else None


def rebuild() -> str:
    """Regenerate the library .blend.

    Returns:
        The last meaningful line the script printed, for reporting.

    Raises:
        BuildError: when the script is missing, fails or times out.
    """
    script = build_script_path()
    if script is None:
        raise BuildError(
            "build_asset_library.py not found. Check the repository root."
        )

    command = [
        bpy.app.binary_path,
        "--background",
        "--factory-startup",  # ignore the artist's startup file and addons
        "--python",
        str(script),
    ]

    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=BUILD_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise BuildError(f"Timed out after {BUILD_TIMEOUT_SECONDS}s") from error
    except OSError as error:
        raise BuildError(f"Cannot run Blender: {error}") from error

    if completed.returncode != 0:
        raise BuildError(_last_meaningful_line(completed.stderr or completed.stdout))

    return _last_meaningful_line(completed.stdout)


def _last_meaningful_line(output: str) -> str:
    """The last non-empty line, which is where the script reports its outcome."""
    lines = [line.strip() for line in (output or "").splitlines() if line.strip()]
    return lines[-1] if lines else "no output"


def refresh_asset_browsers() -> bool:
    """Ask any open Asset Browser to re-read the library from disk.

    The operator only runs with an Asset Browser as the active area, so each
    one is refreshed under a temporary context override, region included: the
    poll rejects an override that names the area alone.

    Returns:
        True when at least one browser was refreshed. False means the artist is
        looking at a stale listing and has to press R, which is worth telling
        them rather than swallowing.
    """
    refreshed = False

    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.ui_type != "ASSETS":
                continue

            region = next(
                (r for r in area.regions if r.type == "WINDOW"), None
            )
            override = {"window": window, "area": area}
            if region is not None:
                override["region"] = region

            try:
                with bpy.context.temp_override(**override):
                    bpy.ops.asset.library_refresh()
                refreshed = True
            except (RuntimeError, TypeError, AttributeError):
                # An unusable area, or an API that moved. The caller reports it.
                pass

            area.tag_redraw()

    return refreshed
