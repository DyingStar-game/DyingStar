"""Addon preferences: where the reference body and the project are, and who the artist is.

Single responsibility: hold the paths and the default credit everything else reads. The addon is installed in
Blender's own folder, so it cannot find them from its position on disk: the artist sets them once, in
Preferences > Add-ons.
"""

from __future__ import annotations

from pathlib import Path

import bpy

ADDON_PACKAGE = __package__
CATALOGUE = ("assets", "_universe", "characters", "human", "human_catalogue.json")


class DYINGSTAR_GarmentPreferences(bpy.types.AddonPreferences):
    bl_idname = ADDON_PACKAGE

    reference_blend: bpy.props.StringProperty(
        name="Reference body",
        description="vitruvian_reference.blend (Nextcloud 3D-Assets/_universe/characters/humanoids/model/)",
        subtype="FILE_PATH",
        default="",
    )
    project_root: bpy.props.StringProperty(
        name="DyingStar project",
        description="Local clone of the DyingStar game repository (the folder with project.godot)",
        subtype="DIR_PATH",
        default="",
    )
    discord_pseudo: bpy.props.StringProperty(name="Discord pseudo", description="Your credit on what you export")
    discord_id: bpy.props.StringProperty(name="Discord id", description="Your numeric Discord id (the credit's key)")

    def draw(self, context) -> None:
        layout = self.layout
        layout.prop(self, "reference_blend")
        layout.prop(self, "project_root")
        row = layout.row()
        row.prop(self, "discord_pseudo")
        row.prop(self, "discord_id")
        root = project_root()
        if root is None:
            layout.label(text="Set the DyingStar project folder to export", icon="ERROR")
        else:
            layout.label(text=f"Garments go to {root.joinpath(*GARMENTS)}", icon="CHECKMARK")


GARMENTS = ("assets", "_universe", "characters", "human", "garments")


def prefs():
    try:
        return bpy.context.preferences.addons[ADDON_PACKAGE].preferences
    except KeyError:
        return None


def project_root() -> Path | None:
    """The project as configured, or None when unset or not the DyingStar project."""
    p = prefs()
    if p is None or not p.project_root:
        return None
    root = Path(bpy.path.abspath(p.project_root)).resolve()
    return root if root.joinpath(*CATALOGUE).is_file() else None


def reference_blend() -> Path | None:
    p = prefs()
    if p is None or not p.reference_blend:
        return None
    path = Path(bpy.path.abspath(p.reference_blend)).resolve()
    return path if path.is_file() else None


def register() -> None:
    bpy.utils.register_class(DYINGSTAR_GarmentPreferences)


def unregister() -> None:
    bpy.utils.unregister_class(DYINGSTAR_GarmentPreferences)
