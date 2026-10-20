"""Per-material metadata stored in the .blend.

Single responsibility: declare the properties the artist fills in, attached to
the material datablock so they survive saving and reopening. Knows nothing
about node trees, export or the panel layout.
"""

from __future__ import annotations

import bpy

from . import tag_vocabulary

# Mirrors the license enum of material.schema.json. Kept short on purpose:
# a longer list invites choices nobody validated.
LICENSE_ITEMS = (
    ("AGPL-3.0", "AGPL-3.0", "Same license as the project"),
    ("CC0-1.0", "CC0-1.0", "Public domain dedication"),
    ("CC-BY-4.0", "CC-BY-4.0", "Attribution required"),
    ("CC-BY-SA-4.0", "CC-BY-SA-4.0", "Attribution, share alike"),
)

# The manifest's alpha modes, plus NONE for an opaque material. The ids are the
# manifest's values upper-cased (scissor -> SCISSOR).
ALPHA_MODE_ITEMS = (
    ("NONE", "None", "Opaque: no alpha block in the manifest"),
    ("SCISSOR", "Scissor", "Cut where the alpha falls below the threshold: hard edge, cheap (decals, grilles)"),
    ("BLEND", "Blend", "Fade by the alpha: soft edge, sorted, costlier (glass, smoke)"),
)


class DYINGSTAR_MaterialTag(bpy.types.PropertyGroup):
    """One tag entry. A collection is the only way to store a list in Blender."""

    name: bpy.props.StringProperty(name="Tag")


class DYINGSTAR_MaterialMetadata(bpy.types.PropertyGroup):
    """Everything the manifest needs that cannot be read from the node tree."""

    display_name: bpy.props.StringProperty(
        name="Display Name",
        description="Human-readable name shown in the Asset Browser",
        default="",
    )
    author: bpy.props.StringProperty(
        name="Author",
        description="Who made this material",
        default="",
    )
    license: bpy.props.EnumProperty(
        name="License",
        items=LICENSE_ITEMS,
        default="AGPL-3.0",
    )
    notes: bpy.props.StringProperty(
        name="Notes",
        description="Deliberate deviations, art-direction choices, known limits",
        default="",
    )
    tags: bpy.props.CollectionProperty(type=DYINGSTAR_MaterialTag)
    tag_to_add: bpy.props.EnumProperty(
        name="Add Tag",
        description="Vocabulary from tools/schema/tags.json",
        items=tag_vocabulary.enum_items,
    )

    # Read from the Mapping node at export time, but overridable: an artist
    # may know the real-world size better than the node does.
    physical_size_x: bpy.props.FloatProperty(
        name="Width (m)",
        description="Real-world width covered by one UV tile",
        default=1.0,
        min=0.001,
        soft_max=20.0,
    )
    physical_size_y: bpy.props.FloatProperty(
        name="Height (m)",
        default=1.0,
        min=0.001,
        soft_max=20.0,
    )

    # Pre-filled from the Alpha input by Detect Maps (a Greater Than node is a
    # scissor and its second value the threshold), but the artist decides: the
    # node tree does not always say whether an edge should be hard or soft.
    alpha_mode: bpy.props.EnumProperty(
        name="Alpha",
        description="How Godot reads the transparency packed into the albedo's alpha",
        items=ALPHA_MODE_ITEMS,
        default="NONE",
    )
    alpha_threshold: bpy.props.FloatProperty(
        name="Threshold",
        description="Scissor only: the alpha under which the surface is cut",
        default=0.5,
        min=0.0,
        max=1.0,
    )

    # Set once the handler has pre-filled this material, so the artist's own
    # edits are never overwritten on the next selection change.
    auto_loaded: bpy.props.BoolProperty(default=False)

    def tag_list(self) -> list[str]:
        return [entry.name for entry in self.tags]

    def has_tag(self, tag: str) -> bool:
        return any(entry.name == tag for entry in self.tags)


CLASSES = (
    DYINGSTAR_MaterialTag,
    DYINGSTAR_MaterialMetadata,
)


def register() -> None:
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    bpy.types.Material.dyingstar = bpy.props.PointerProperty(
        type=DYINGSTAR_MaterialMetadata
    )


def unregister() -> None:
    del bpy.types.Material.dyingstar
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
