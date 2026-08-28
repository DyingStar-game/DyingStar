"""Addon preferences: where the library lives.

Single responsibility: hold the one path everything else depends on, and
derive the project paths from it.

The addon is installed into Blender's own addons folder, so it cannot deduce
the repository location from its own position on disk. The artist points at it
once, in Preferences > Add-ons.
"""

from __future__ import annotations

from pathlib import Path

import bpy

# Package name of the addon root, used to look preferences up at runtime.
ADDON_PACKAGE = __package__

# Paths inside the repository, relative to its root.
_MATERIALS_SUBPATH = ("assets", "_universe", "_shared", "materials")
_TAGS_SUBPATH = ("tools", "schema", "tags.json")
# Authoring inputs, on the Blender side: the build wipes that tree, and
# nothing there is a game resource.
_SOURCES_SUBPATH = ("assets_blender", "_universe", "_shared", "materials", "src")


class DYINGSTAR_AddonPreferences(bpy.types.AddonPreferences):
    bl_idname = ADDON_PACKAGE

    repository_root: bpy.props.StringProperty(
        name="Repository Root",
        description="Local clone of the Dying Star repository",
        subtype="DIR_PATH",
        default="",
    )

    def draw(self, context) -> None:
        layout = self.layout
        layout.prop(self, "repository_root")

        root = resolve_root()
        if root is None:
            layout.label(text="Set the repository root to enable the library", icon="ERROR")
            return

        if not tags_path().is_file():
            layout.label(
                text=f"No tags.json under {root.name}/tools/schema", icon="ERROR"
            )
        else:
            layout.label(text=f"Library: {materials_dir()}", icon="CHECKMARK")


def resolve_root() -> Path | None:
    """The repository root as configured, or None when unset or invalid."""
    try:
        preferences = bpy.context.preferences.addons[ADDON_PACKAGE].preferences
    except KeyError:
        return None

    raw = preferences.repository_root.strip()
    if not raw:
        return None

    root = Path(bpy.path.abspath(raw))
    return root if root.is_dir() else None


def materials_dir() -> Path | None:
    root = resolve_root()
    return root.joinpath(*_MATERIALS_SUBPATH) if root else None


def tags_path() -> Path | None:
    root = resolve_root()
    return root.joinpath(*_TAGS_SUBPATH) if root else None


def sources_dir() -> Path | None:
    """Where artists keep the maps they build materials from.

    Distinct from the library: a file here has not been published, and the
    export is what moves it into a material folder.
    """
    root = resolve_root()
    return root.joinpath(*_SOURCES_SUBPATH) if root else None


CLASSES = (DYINGSTAR_AddonPreferences,)


def register() -> None:
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister() -> None:
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
