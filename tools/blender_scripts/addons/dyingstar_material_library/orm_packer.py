"""Packing occlusion, roughness and metalness into a single texture.

Single responsibility: build the packed image and rewire the shader graph to
read from it. Knows nothing about panels, manifests or the library layout, and
is handed the path it should write to.

Three grayscale maps sampled separately cost three textures at runtime and
three files in the repository, to carry three channels' worth of data. Packed
into the red, green and blue of one image they cost one of each.

The channel order is the one material_builder writes and map_extractor reads,
so a packed material survives a round trip through the library unchanged.
"""

from __future__ import annotations

from pathlib import Path

import bpy
import numpy as np

from . import map_extractor

# Role to channel index, in the order the rest of the pipeline expects.
CHANNELS = {"ao": 0, "roughness": 1, "metallic": 2}

_MIX_NODES = ("ShaderNodeMix", "ShaderNodeMixRGB")
_COLUMN_WIDTH = 300.0


class PackError(RuntimeError):
    """Raised when the maps cannot be packed as they stand."""


def can_pack(images: dict) -> bool:
    """Whether the three separate maps are present and share one size."""
    if any(images.get(role) is None for role in CHANNELS):
        return False
    if images.get("orm") is not None:
        return False
    return len({tuple(images[role].size) for role in CHANNELS}) == 1


def target_path(sources_dir: Path, material_id: str, descriptor: str) -> Path:
    """Where the packed map is written, before any export.

    On the authoring side of the repository, never straight into the library:
    the material may not be published yet, its id may still change, and the
    artist may never export at all. Letting export() remain the only writer of
    a material folder is what keeps the library's state predictable.
    """
    return sources_dir / material_id / f"tex_{descriptor}_orm.png"


def pack(material: bpy.types.Material, images: dict, target: Path) -> bpy.types.Image:
    """Write the packed map, rewire the material, and return the new image."""
    if not can_pack(images):
        raise PackError("Needs an ao, a roughness and a metallic map, all the same size")

    width, height = images["ao"].size
    channels = {role: _read_channel(images[role]) for role in CHANNELS}

    target.parent.mkdir(parents=True, exist_ok=True)
    packed = _build_image(target.stem, width, height, channels)
    _save(packed, target)
    _rewire(material, packed, _source_nodes(material, images))

    return packed


def _read_channel(image: bpy.types.Image) -> np.ndarray:
    """The red channel of a map, as raw stored values.

    The colour space is forced to Non-Color for the read. These are data maps,
    and one mistakenly tagged sRGB would otherwise come back gamma-decoded,
    which would show up as a material subtly too smooth or too metallic.
    """
    original = image.colorspace_settings.name
    try:
        image.colorspace_settings.name = "Non-Color"
        buffer = np.empty(len(image.pixels), dtype=np.float32)
        image.pixels.foreach_get(buffer)
    finally:
        image.colorspace_settings.name = original

    return buffer.reshape(-1, 4)[:, 0]


def _build_image(
    name: str, width: int, height: int, channels: dict[str, np.ndarray]
) -> bpy.types.Image:
    """A byte image holding the three maps in its colour channels."""
    packed = bpy.data.images.new(name, width, height, alpha=False, float_buffer=False)
    packed.colorspace_settings.name = "Non-Color"

    buffer = np.ones((width * height, 4), dtype=np.float32)
    for role, index in CHANNELS.items():
        buffer[:, index] = channels[role]

    packed.pixels.foreach_set(buffer.ravel())
    return packed


def _save(image: bpy.types.Image, target: Path) -> None:
    image.filepath_raw = str(target)
    image.file_format = "PNG"
    try:
        image.save()
    except (RuntimeError, OSError) as error:
        raise PackError(f"Cannot write '{target.name}': {error}") from error


def _source_nodes(material: bpy.types.Material, images: dict) -> list[bpy.types.Node]:
    """The Image Texture nodes holding the maps about to be replaced.

    Found by the image they carry rather than by walking the graph, so a node
    wired through an unusual chain is still removed with the others.
    """
    replaced = {images[role].name for role in CHANNELS}
    return [
        node
        for node in material.node_tree.nodes
        if node.bl_idname == "ShaderNodeTexImage"
        and node.image is not None
        and node.image.name in replaced
    ]


def _rewire(
    material: bpy.types.Material,
    packed: bpy.types.Image,
    source_nodes: list[bpy.types.Node],
) -> None:
    """Replace the three maps with the packed one, split back into channels."""
    tree = material.node_tree
    principled = map_extractor.find_principled(material)
    if principled is None:
        raise PackError("No Principled BSDF found in this material")

    anchor = source_nodes[0].location.copy() if source_nodes else None

    texture = tree.nodes.new("ShaderNodeTexImage")
    texture.image = packed
    texture.label = "orm"
    texture.name = "tex_orm"

    separate = tree.nodes.new("ShaderNodeSeparateColor")
    separate.label = "ORM"

    if anchor is not None:
        texture.location = anchor
        separate.location = (anchor[0] + _COLUMN_WIDTH, anchor[1])

    tree.links.new(texture.outputs["Color"], separate.inputs["Color"])
    tree.links.new(separate.outputs["Green"], principled.inputs["Roughness"])
    tree.links.new(separate.outputs["Blue"], principled.inputs["Metallic"])

    occlusion = _occlusion_socket(principled)
    if occlusion is not None:
        tree.links.new(separate.outputs["Red"], occlusion)

    for node in source_nodes:
        tree.nodes.remove(node)


def _occlusion_socket(principled: bpy.types.Node):
    """The Mix input the occlusion map feeds, when the graph has one.

    material_builder wires albedo into A and occlusion into B, and
    map_extractor reads it back the same way. A material whose base colour
    comes straight from an image has nowhere to put occlusion, and the packed
    red channel is simply left unconnected rather than inventing a Mix node the
    artist did not ask for.
    """
    socket = principled.inputs["Base Color"]
    if not socket.is_linked:
        return None

    node = socket.links[0].from_node
    if node.bl_idname not in _MIX_NODES:
        return None

    for name in ("B", "Color2"):
        if name in node.inputs:
            return node.inputs[name]
    return None
