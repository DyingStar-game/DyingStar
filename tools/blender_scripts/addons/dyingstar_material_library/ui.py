"""The panels the artist sees.

Single responsibility: lay out the metadata fields and the detected maps in
the Material Properties tab. Contains no logic, every action delegates to an
operator.

The layout is split by scope. Everything in the Material Properties tab
concerns the active material and nothing else. Rebuilding the library acts on
every published material at once, so it lives in the Asset Browser's Library
menu instead: that is where the library itself is on screen, and the action
needs no material at all. The two used to be adjacent buttons of identical
weight in the same panel, which read as a pair they never were.
"""

from __future__ import annotations

import bpy

from . import (
    bpy_loader,
    exporter,
    map_extractor,
    orm_packer,
    preferences,
    shared_rules,
    tag_vocabulary,
)


def _size_label(image) -> str:
    if image is None or image.size[0] == 0:
        return "?"
    return f"{image.size[0]}x{image.size[1]}"


def _metadata_issues(images: dict, physical_size_m: tuple) -> list:
    """Run the shared rules in metadata-only mode.

    The panel redraws constantly, so pixel data is deliberately not read here.
    Rules needing it are skipped and run again, in full, at export time.
    """
    try:
        rules = shared_rules.load()
        samples, issues = bpy_loader.build_samples(images, with_pixels=False)
    except shared_rules.RulesUnavailable as error:
        return [("error", str(error))]

    issues.extend(rules.inspect(samples, None, physical_size_m))
    return [(issue.severity, issue.message) for issue in issues]


def _problem(layout, text: str, detail: str = "") -> None:
    """A blocking problem, in the only colour Blender's layout API offers."""
    row = layout.row()
    row.alert = True
    row.label(text=text, icon="ERROR")
    if detail:
        layout.label(text=detail)


class _MaterialPanel:
    """Shared placement and availability for every panel of this add-on."""

    bl_space_type = "PROPERTIES"
    bl_region_type = "WINDOW"
    bl_context = "material"

    @classmethod
    def poll(cls, context) -> bool:
        return context.object is not None and context.object.active_material is not None


class _MaterialSubPanel(_MaterialPanel):
    """A section of the material panel, hidden while the add-on is unconfigured."""

    bl_parent_id = "DYINGSTAR_PT_material_library"

    @classmethod
    def poll(cls, context) -> bool:
        return _MaterialPanel.poll(context) and preferences.materials_dir() is not None


class DYINGSTAR_PT_material_library(_MaterialPanel, bpy.types.Panel):
    """What this material is, and the single action that publishes it."""

    bl_label = "Dying Star Library"
    bl_idname = "DYINGSTAR_PT_material_library"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context) -> None:
        layout = self.layout
        material = context.object.active_material

        if preferences.materials_dir() is None:
            _problem(
                layout,
                "Set the repository root",
                "Preferences > Add-ons > Dying Star",
            )
            return

        self._draw_identity(layout, material)
        layout.separator()
        layout.operator("dyingstar.export_material", icon="EXPORT")

    @staticmethod
    def _draw_identity(layout, material) -> None:
        """The id that will be written, and whether it is already published."""
        try:
            material_id = exporter.slugify(material.name)
        except exporter.ExportError as error:
            _problem(layout, str(error))
            return

        box = layout.box()
        row = box.row()
        row.label(text="Library id")
        row.label(text=material_id)

        if material_id != material.name:
            _problem(
                box,
                f"Rename the material to '{material_id}'",
                "Godot matches models to materials by this name.",
            )

        family, family_error = tag_vocabulary.check_family(material_id)
        if family_error:
            _problem(box, family_error, "The family drives footstep sounds in game.")
        elif family:
            row = box.row()
            row.label(text="Family")
            row.label(text=family)

        if exporter.find_manifest(material_id) is not None:
            box.label(text="Already in the library", icon="CHECKMARK")
            box.operator("dyingstar.load_material_from_library", icon="IMPORT")


class DYINGSTAR_PT_material_metadata(_MaterialSubPanel, bpy.types.Panel):
    """Filled once per material, so it starts collapsed."""

    bl_label = "Metadata"
    bl_idname = "DYINGSTAR_PT_material_metadata"
    bl_options = {"DEFAULT_CLOSED"}

    def draw(self, context) -> None:
        metadata = context.object.active_material.dyingstar

        column = self.layout.column(align=True)
        column.prop(metadata, "display_name")
        column.prop(metadata, "author")
        column.prop(metadata, "license")
        column.prop(metadata, "notes")

        self._draw_tags(self.layout, metadata)

    @staticmethod
    def _draw_tags(layout, metadata) -> None:
        box = layout.box()
        box.label(text="Tags")

        row = box.row(align=True)
        row.prop(metadata, "tag_to_add", text="")
        row.operator("dyingstar.add_material_tag", text="", icon="ADD")

        if not metadata.tags:
            box.label(text="No tag yet", icon="INFO")
            return

        for index, entry in enumerate(metadata.tags):
            row = box.row(align=True)
            row.label(text=entry.name)
            row.operator("dyingstar.remove_material_tag", text="", icon="X").index = index


class DYINGSTAR_PT_material_maps(_MaterialSubPanel, bpy.types.Panel):
    """Re-read on every iteration of the shader graph, so it stays open."""

    bl_label = "Maps"
    bl_idname = "DYINGSTAR_PT_material_maps"

    def draw(self, context) -> None:
        layout = self.layout
        material = context.object.active_material
        metadata = material.dyingstar

        # One walk of the node tree per redraw. The panel redraws constantly, and
        # the button's availability and the list below both read this result.
        result = map_extractor.extract(material)

        row = layout.row(align=True)
        row.operator("dyingstar.detect_material_maps", icon="VIEWZOOM")
        # Only drawn when there are three separate maps to merge, so the button
        # is absent rather than greyed out on a material with nothing to pack.
        if orm_packer.can_pack(result.images):
            row.operator("dyingstar.pack_orm", icon="IMAGE_RGB")

        box = layout.box()
        box.label(text="Real-world tile size")
        row = box.row(align=True)
        row.prop(metadata, "physical_size_x")
        row.prop(metadata, "physical_size_y")

        self._draw_detected(layout, result, metadata)

    @staticmethod
    def _draw_detected(layout, result, metadata) -> None:
        """Show what the exporter would pick up, so surprises happen here."""
        box = layout.box()
        box.label(text="Detected maps")

        if not result.images:
            _problem(box, "Nothing detected")
            return

        for role in sorted(result.images):
            image = result.images[role]
            row = box.row()
            row.label(text=role)
            row.label(text=image.name if image is not None else "(empty)")
            row.label(text=_size_label(image))

        tile_size = (metadata.physical_size_x, metadata.physical_size_y)
        for severity, message in _metadata_issues(result.images, tile_size):
            if severity == "error":
                _problem(box, message)
            else:
                box.label(text=message, icon="INFO")

        for warning in result.warnings:
            _problem(box, warning)


## The Asset Browser's own Library menu. Named rather than imported, because a
## Blender that predates it must still be able to enable the add-on.
_LIBRARY_MENU = "ASSETBROWSER_MT_library"


def _draw_library_rebuild(self, context) -> None:
    """Add the rebuild action to the Asset Browser's Library menu.

    Not to the header: an appended header entry lands after the search field,
    at the far right of the editor, which is nowhere near the library it acts
    on. And not beside Blender's own refresh either, which only re-reads the
    library from disk while this regenerates it from the manifests. Two
    look-alike buttons doing different things would be a trap.
    """
    self.layout.separator()
    self.layout.operator(
        "dyingstar.rebuild_library",
        text="Rebuild Dying Star Library",
        icon="FILE_BLEND",
    )


CLASSES = (
    DYINGSTAR_PT_material_library,
    DYINGSTAR_PT_material_metadata,
    DYINGSTAR_PT_material_maps,
)


def register() -> None:
    for cls in CLASSES:
        bpy.utils.register_class(cls)

    menu = getattr(bpy.types, _LIBRARY_MENU, None)
    if menu is not None:
        menu.append(_draw_library_rebuild)


def unregister() -> None:
    menu = getattr(bpy.types, _LIBRARY_MENU, None)
    if menu is not None:
        menu.remove(_draw_library_rebuild)

    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
