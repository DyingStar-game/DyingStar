"""Operators: the actions the artist can trigger.

Single responsibility: bridge the UI and the logic modules, and report back
through Blender's own reporting system. No node walking, no file writing —
those live in map_extractor and exporter.
"""

from __future__ import annotations

import bpy

from . import (  # noqa: E402
    bpy_loader,
    exporter,
    library_builder,
    map_extractor,
    orm_packer,
    preferences,
    preview_writer,
    properties,
    shared_rules,
    tag_vocabulary,
)


def _active_material(context) -> bpy.types.Material | None:
    obj = context.object
    return obj.active_material if obj is not None else None


class DYINGSTAR_OT_add_tag(bpy.types.Operator):
    bl_idname = "dyingstar.add_material_tag"
    bl_label = "Add Tag"
    bl_description = "Add the selected tag to this material"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context) -> bool:
        return _active_material(context) is not None

    def execute(self, context):
        metadata = _active_material(context).dyingstar
        tag = metadata.tag_to_add

        if not tag:
            self.report({"WARNING"}, "No tag selected")
            return {"CANCELLED"}

        if metadata.has_tag(tag):
            self.report({"INFO"}, f"'{tag}' is already set")
            return {"CANCELLED"}

        metadata.tags.add().name = tag
        return {"FINISHED"}


class DYINGSTAR_OT_remove_tag(bpy.types.Operator):
    bl_idname = "dyingstar.remove_material_tag"
    bl_label = "Remove Tag"
    bl_description = "Remove this tag from the material"
    bl_options = {"REGISTER", "UNDO"}

    index: bpy.props.IntProperty()

    @classmethod
    def poll(cls, context) -> bool:
        return _active_material(context) is not None

    def execute(self, context):
        _active_material(context).dyingstar.tags.remove(self.index)
        return {"FINISHED"}


class DYINGSTAR_OT_detect_maps(bpy.types.Operator):
    """Read the node tree and report what the exporter would pick up."""

    bl_idname = "dyingstar.detect_material_maps"
    bl_label = "Detect Maps"
    bl_description = "Analyse the node tree and fill in the tile size"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context) -> bool:
        return _active_material(context) is not None

    def execute(self, context):
        material = _active_material(context)
        result = map_extractor.extract(material)

        for warning in result.warnings:
            self.report({"WARNING"}, warning)

        if not result.images:
            self.report({"ERROR"}, "No texture found behind the Principled BSDF")
            return {"CANCELLED"}

        metadata = material.dyingstar
        metadata.physical_size_x = result.physical_size_m[0]
        metadata.physical_size_y = result.physical_size_m[1]

        self.report({"INFO"}, f"Found: {', '.join(sorted(result.images))}")
        return {"FINISHED"}


class DYINGSTAR_OT_export_material(bpy.types.Operator):
    """Write this material into the shared library."""

    bl_idname = "dyingstar.export_material"
    bl_label = "Export to Library"
    bl_description = "Copy the maps and write material.json into the library"
    bl_options = {"REGISTER"}

    @classmethod
    def poll(cls, context) -> bool:
        return _active_material(context) is not None

    def execute(self, context):
        material = _active_material(context)
        metadata = material.dyingstar

        missing = self._missing_fields(metadata)
        if missing:
            self.report({"ERROR"}, f"Fill in: {', '.join(missing)}")
            return {"CANCELLED"}

        _, family_error = tag_vocabulary.check_family(exporter.slugify(material.name))
        if family_error:
            self.report({"ERROR"}, family_error)
            return {"CANCELLED"}

        result = map_extractor.extract(material)
        for warning in result.warnings:
            self.report({"WARNING"}, warning)

        if not result.is_usable():
            self.report({"ERROR"}, "An albedo and a normal map are required")
            return {"CANCELLED"}

        if not self._maps_pass_rules(
            result.images, (metadata.physical_size_x, metadata.physical_size_y)
        ):
            return {"CANCELLED"}

        try:
            written = exporter.export(
                material_name=material.name,
                images=result.images,
                metadata={
                    "display_name": metadata.display_name,
                    "tags": metadata.tag_list(),
                    "physical_size_m": (
                        metadata.physical_size_x,
                        metadata.physical_size_y,
                    ),
                    "license": metadata.license,
                    "author": metadata.author,
                    "notes": metadata.notes,
                },
            )
        except exporter.ExportError as error:
            self.report({"ERROR"}, str(error))
            return {"CANCELLED"}

        self.report({"INFO"}, written.summary())
        if written.already_in_place:
            self.report(
                {"INFO"},
                "Read straight from the library, nothing to copy: "
                + ", ".join(sorted(written.already_in_place)),
            )
        self._write_preview(material, result.images, written.folder)
        self._rebuild_library()
        return {"FINISHED"}

    def _write_preview(self, material, images: dict, folder) -> None:
        """Add the review preview. Its absence would fail validate.py."""
        try:
            _, rendered = preview_writer.write(material, images, folder)
        except preview_writer.PreviewError as error:
            self.report({"WARNING"}, str(error))
            return

        if not rendered:
            self.report(
                {"WARNING"},
                "Preview taken from the albedo: it shows no roughness or metallic "
                "response. Replace preview.jpg by hand for a better one.",
            )

    def _rebuild_library(self) -> None:
        """Refresh the Asset Browser so the material shows up immediately.

        A failure here does not undo the export: the files are on disk and the
        library can always be rebuilt from the command line.
        """
        try:
            library_builder.rebuild()
        except library_builder.BuildError as error:
            self.report({"WARNING"}, f"Exported, but library not rebuilt: {error}")
            return

        if library_builder.refresh_asset_browsers():
            self.report({"INFO"}, "Asset Browser library rebuilt")
        else:
            self.report(
                {"WARNING"},
                "Library rebuilt on disk, but no Asset Browser could be "
                "refreshed. Press R in the Asset Browser to see it.",
            )

    def _maps_pass_rules(self, images: dict, physical_size_m: tuple) -> bool:
        """Full validation, pixels included, using the shared rules.

        This is the same code the command-line validator runs, so a material
        accepted here cannot be rejected in CI. Warnings are reported but do
        not block; errors do.
        """
        try:
            rules = shared_rules.load()
            samples, issues = bpy_loader.build_samples(images, with_pixels=True)
        except shared_rules.RulesUnavailable as error:
            self.report({"WARNING"}, f"Rules unavailable, exporting unchecked: {error}")
            return True

        issues.extend(rules.inspect(samples, None, physical_size_m))

        errors = [issue for issue in issues if issue.severity == "error"]
        for issue in issues:
            self.report(
                {"ERROR"} if issue.severity == "error" else {"WARNING"}, issue.message
            )

        return not errors

    @staticmethod
    def _missing_fields(metadata) -> list[str]:
        missing = []
        if not metadata.display_name.strip():
            missing.append("Display Name")
        if not metadata.author.strip():
            missing.append("Author")
        if not metadata.tag_list():
            missing.append("at least one tag")
        return missing


class DYINGSTAR_OT_pack_orm(bpy.types.Operator):
    """Pack the occlusion, roughness and metalness maps into one texture."""

    bl_idname = "dyingstar.pack_orm"
    bl_label = "Pack into ORM"
    bl_description = (
        "Combine the ao, roughness and metallic maps into one ORM texture and "
        "rewire the material to read it"
    )
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context) -> bool:
        material = _active_material(context)
        if material is None or preferences.sources_dir() is None:
            return False
        return orm_packer.can_pack(map_extractor.extract(material).images)

    def execute(self, context):
        material = _active_material(context)

        try:
            material_id = exporter.slugify(material.name)
            target = orm_packer.target_path(
                preferences.sources_dir(),
                material_id,
                exporter.descriptor_from_id(material_id),
            )
            orm_packer.pack(material, map_extractor.extract(material).images, target)
        except (orm_packer.PackError, exporter.ExportError) as error:
            self.report({"ERROR"}, str(error))
            return {"CANCELLED"}

        self.report({"INFO"}, f"Packed ORM written to {target}")
        return {"FINISHED"}


class DYINGSTAR_OT_load_from_library(bpy.types.Operator):
    """Pre-fill the panel from a material already published in the library."""

    bl_idname = "dyingstar.load_material_from_library"
    bl_label = "Load from Library"
    bl_description = "Read this material's existing manifest into the fields"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context) -> bool:
        material = _active_material(context)
        if material is None:
            return False
        try:
            return exporter.find_manifest(exporter.slugify(material.name)) is not None
        except exporter.ExportError:
            return False

    def execute(self, context):
        material = _active_material(context)

        try:
            manifest = exporter.load_manifest(exporter.slugify(material.name))
        except exporter.ExportError as error:
            self.report({"ERROR"}, str(error))
            return {"CANCELLED"}

        metadata = material.dyingstar
        metadata.display_name = manifest.get("display_name", "")
        metadata.author = manifest.get("author", "")
        metadata.notes = manifest.get("notes", "")

        license_value = manifest.get("license")
        if license_value in {item[0] for item in properties.LICENSE_ITEMS}:
            metadata.license = license_value

        size = manifest.get("physical_size_m", [1.0, 1.0])
        metadata.physical_size_x = size[0]
        metadata.physical_size_y = size[1]

        metadata.tags.clear()
        for tag in manifest.get("tags", []):
            metadata.tags.add().name = tag

        self.report({"INFO"}, f"Loaded metadata for '{material.name}'")
        return {"FINISHED"}


class DYINGSTAR_OT_rebuild_library(bpy.types.Operator):
    """Regenerate the Asset Browser library from every published manifest."""

    bl_idname = "dyingstar.rebuild_library"
    bl_label = "Rebuild Library"
    bl_description = "Re-run build_asset_library.py in a separate Blender process"
    bl_options = {"REGISTER"}

    @classmethod
    def poll(cls, context) -> bool:
        return library_builder.build_script_path() is not None

    def execute(self, context):
        try:
            summary = library_builder.rebuild()
        except library_builder.BuildError as error:
            self.report({"ERROR"}, str(error))
            return {"CANCELLED"}

        if not library_builder.refresh_asset_browsers():
            summary += " (press R in the Asset Browser to see it)"
        self.report({"INFO"}, summary)
        return {"FINISHED"}


CLASSES = (
    DYINGSTAR_OT_add_tag,
    DYINGSTAR_OT_remove_tag,
    DYINGSTAR_OT_detect_maps,
    DYINGSTAR_OT_pack_orm,
    DYINGSTAR_OT_load_from_library,
    DYINGSTAR_OT_rebuild_library,
    DYINGSTAR_OT_export_material,
)


def register() -> None:
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister() -> None:
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
