"""Automatic metadata loading.

Single responsibility: when the artist selects a material that already exists
in the library and whose fields are still untouched, fill them in.

Why a handler rather than the panel: Blender forbids calling operators or
mutating data from a draw() callback, so the panel can only display. The
depsgraph handler is the supported place to react to a selection change.
"""

from __future__ import annotations

import bpy

from . import exporter, properties

# Writing to a material inside a depsgraph handler triggers another depsgraph
# update. Without this guard the handler re-enters itself indefinitely.
_running = False


def _apply_manifest(metadata, manifest: dict) -> None:
    """Copy a manifest into the panel properties."""
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


def _should_load(material: bpy.types.Material) -> bool:
    """Load once, and never over data the artist has started editing."""
    if material.library is not None:
        return False  # linked material: read-only, nothing to fill in

    metadata = material.dyingstar
    if metadata.auto_loaded:
        return False

    return not metadata.display_name.strip() and not metadata.tags


def _load_active_material(context) -> None:
    obj = getattr(context, "object", None)
    material = obj.active_material if obj is not None else None
    if material is None or not _should_load(material):
        return

    try:
        manifest = exporter.load_manifest(exporter.slugify(material.name))
    except exporter.ExportError:
        return  # not published yet, or unreadable: leave the fields alone

    _apply_manifest(material.dyingstar, manifest)
    material.dyingstar.auto_loaded = True


@bpy.app.handlers.persistent
def on_depsgraph_update(scene, depsgraph) -> None:
    global _running
    if _running:
        return

    _running = True
    try:
        _load_active_material(bpy.context)
    except Exception:  # noqa: BLE001 - a handler must never break the session
        pass
    finally:
        _running = False


def register() -> None:
    if on_depsgraph_update not in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.append(on_depsgraph_update)


def unregister() -> None:
    if on_depsgraph_update in bpy.app.handlers.depsgraph_update_post:
        bpy.app.handlers.depsgraph_update_post.remove(on_depsgraph_update)
