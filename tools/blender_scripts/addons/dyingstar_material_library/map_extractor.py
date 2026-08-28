"""Node tree analysis: work out which image plays which PBR role.

Single responsibility: given a material, walk backwards from the Principled
BSDF and report the image found behind each of its inputs. Knows nothing about
files, manifests or the UI.

Identification is by connection, not by file name. A file called
"Rough_02_final.png" wired into the Roughness input is the roughness map,
whatever the texturing tool decided to call it.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import bpy

# Node types the walker knows how to pass through on its way to an image.
_NORMAL_MAP = "ShaderNodeNormalMap"
_BUMP = "ShaderNodeBump"
_SEPARATE_COLOR = "ShaderNodeSeparateColor"
_MIX = "ShaderNodeMix"
_MIX_LEGACY = "ShaderNodeMixRGB"
_IMAGE = "ShaderNodeTexImage"
_MAPPING = "ShaderNodeMapping"
_PRINCIPLED = "ShaderNodeBsdfPrincipled"

# Channel each role occupies in a packed ORM map, per the manifest schema.
# Occlusion sits in red, but it reaches the Principled through the base colour
# mix rather than a direct link, so only these two can be checked.
_ORM_CHANNELS = {"roughness": "Green", "metallic": "Blue"}

# How many nodes to traverse before giving up, in case of a cyclic or
# pathological graph.
_MAX_DEPTH = 12


@dataclass
class ExtractionResult:
    """What the walker found, plus what it could not make sense of."""

    # map role -> image datablock
    images: dict[str, bpy.types.Image] = field(default_factory=dict)
    # real-world size covered by one UV tile, derived from the Mapping node
    physical_size_m: tuple[float, float] = (1.0, 1.0)
    warnings: list[str] = field(default_factory=list)

    def is_usable(self) -> bool:
        """A library material needs at least a base colour and a normal."""
        return "albedo" in self.images and "normal" in self.images


def find_principled(material: bpy.types.Material) -> bpy.types.Node | None:
    """Locate the Principled BSDF actually feeding the material output."""
    if not material.use_nodes or material.node_tree is None:
        return None

    for node in material.node_tree.nodes:
        if node.bl_idname == _PRINCIPLED:
            return node
    return None


def _linked_node(socket) -> bpy.types.Node | None:
    """The node feeding a socket, or None when nothing is connected."""
    if not socket.is_linked:
        return None
    return socket.links[0].from_node


def _walk_to_image(socket, depth: int = 0) -> bpy.types.Node | None:
    """Follow links backwards until an Image Texture node is reached.

    Passes through nodes that only reshape data (colour separation, mixing)
    without changing which image is ultimately responsible for the value.
    """
    if depth > _MAX_DEPTH:
        return None

    node = _linked_node(socket)
    if node is None:
        return None

    if node.bl_idname == _IMAGE:
        return node

    if node.bl_idname == _SEPARATE_COLOR:
        return _walk_to_image(node.inputs["Color"], depth + 1)

    if node.bl_idname in (_MIX, _MIX_LEGACY):
        # Convention from material_builder: A is the base, B the modulation.
        for input_name in ("A", "Color1", "B", "Color2"):
            if input_name in node.inputs:
                found = _walk_to_image(node.inputs[input_name], depth + 1)
                if found is not None:
                    return found

    return None


def _separated_channel(socket) -> tuple[bpy.types.Image | None, str]:
    """Image and channel name behind a socket fed by a Separate Color node.

    Returns (None, "") when the socket is not wired through a channel split,
    which is the ordinary case of one image per role.
    """
    node = _linked_node(socket)
    if node is None or node.bl_idname != _SEPARATE_COLOR:
        return None, ""

    image_node = _walk_to_image(node.inputs["Color"])
    if image_node is None:
        return None, ""
    return image_node.image, socket.links[0].from_socket.name


def _extract_base_color(principled: bpy.types.Node, result: ExtractionResult) -> None:
    """Base Color may come straight from an image, or through an AO multiply."""
    socket = principled.inputs["Base Color"]
    node = _linked_node(socket)

    if node is None:
        result.warnings.append("Base Color is not connected to any texture")
        return

    if node.bl_idname == _IMAGE:
        result.images["albedo"] = node.image
        return

    if node.bl_idname in (_MIX, _MIX_LEGACY):
        base_input = "A" if "A" in node.inputs else "Color1"
        modulation_input = "B" if "B" in node.inputs else "Color2"

        albedo = _walk_to_image(node.inputs[base_input])
        occlusion = _walk_to_image(node.inputs[modulation_input])

        if albedo is not None:
            result.images["albedo"] = albedo.image
        if occlusion is not None and occlusion is not albedo:
            result.images["ao"] = occlusion.image
        elif occlusion is None:
            _warn_flat_modulation(node.inputs[modulation_input], result)
        return

    result.warnings.append(
        f"Base Color goes through an unsupported node ({node.bl_idname})"
    )


def _warn_flat_modulation(socket, result: ExtractionResult) -> None:
    """Name a base colour tint that the library cannot carry.

    The convention is albedo in A, occlusion in B. A flat colour in B instead
    is a tint the artist sees in the viewport but which lives in the node tree,
    not in the image. Only the image is published, so the material would come
    out of the library paler than it was authored, with nothing in the manifest
    to explain the difference. The library does not bake colour operations: the
    published albedo is the final image, so the tint has to be flattened into
    it before export.
    """
    if socket.is_linked:
        return

    value = getattr(socket, "default_value", None)
    if value is None:
        return

    red, green, blue = (round(channel, 3) for channel in tuple(value)[:3])
    if red == green == blue == 1.0:
        return

    result.warnings.append(
        f"Base Color is tinted by a flat colour ({red}, {green}, {blue}) "
        "instead of an occlusion map. Flatten it into the albedo image, "
        "the library publishes the image only"
    )


def _extract_normal_and_height(
    principled: bpy.types.Node, result: ExtractionResult
) -> None:
    """Unwind the Bump / Normal Map chain, in whichever order it was built."""
    node = _linked_node(principled.inputs["Normal"])
    if node is None:
        return

    if node.bl_idname == _BUMP:
        height = _walk_to_image(node.inputs["Height"])
        if height is not None:
            result.images["height"] = height.image
        node = _linked_node(node.inputs["Normal"])

    if node is not None and node.bl_idname == _NORMAL_MAP:
        normal = _walk_to_image(node.inputs["Color"])
        if normal is not None:
            result.images["normal"] = normal.image
    elif node is not None:
        result.warnings.append(
            f"Normal input goes through an unsupported node ({node.bl_idname})"
        )


def _extract_scalar(
    principled: bpy.types.Node,
    input_name: str,
    map_name: str,
    result: ExtractionResult,
) -> None:
    """Roughness and metallic: an image, possibly via an ORM channel split."""
    node = _walk_to_image(principled.inputs[input_name])
    if node is not None:
        result.images[map_name] = node.image


def _extract_simple(
    principled: bpy.types.Node,
    input_name: str,
    map_name: str,
    result: ExtractionResult,
) -> None:
    node = _linked_node(principled.inputs.get(input_name))
    if node is not None and node.bl_idname == _IMAGE:
        result.images[map_name] = node.image


def _collapse_packed_orm(principled: bpy.types.Node, result: ExtractionResult) -> None:
    """Record a packed ORM as one map instead of three.

    Occlusion, roughness and metalness are commonly shipped in the three
    channels of a single image, split by a Separate Color node. Each role would
    otherwise point at that same image, and the exporter would write three
    copies of it — heavier than the separate maps it was meant to replace.
    """
    packed, roughness_channel = _separated_channel(principled.inputs["Roughness"])
    metallic_image, metallic_channel = _separated_channel(principled.inputs["Metallic"])

    if packed is None or packed is not metallic_image:
        return

    # A swapped channel yields a material that loads and looks wrong, which is
    # the kind of silent failure worth naming at export time.
    for role, channel in (
        ("roughness", roughness_channel),
        ("metallic", metallic_channel),
    ):
        if channel != _ORM_CHANNELS[role]:
            result.warnings.append(
                f"Packed ORM: {role} reads the {channel} channel, "
                f"expected {_ORM_CHANNELS[role]}"
            )

    separate_occlusion = result.images.get("ao")
    for role in ("ao", "roughness", "metallic"):
        if result.images.get(role) is packed:
            del result.images[role]
    result.images["orm"] = packed

    if separate_occlusion is not None and separate_occlusion is not packed:
        result.warnings.append(
            "A packed ORM and a separate ao map cannot coexist: the manifest "
            "accepts one or the other"
        )


def _extract_physical_size(
    material: bpy.types.Material, result: ExtractionResult
) -> None:
    """Derive the tile size from the Mapping node, which stores its inverse."""
    for node in material.node_tree.nodes:
        if node.bl_idname != _MAPPING:
            continue
        scale = node.inputs["Scale"].default_value
        if scale[0] <= 0 or scale[1] <= 0:
            result.warnings.append("Mapping node has a non-positive scale")
            return
        result.physical_size_m = (
            round(1.0 / scale[0], 4),
            round(1.0 / scale[1], 4),
        )
        return


def extract(material: bpy.types.Material) -> ExtractionResult:
    """Analyse a material and report which image plays which role."""
    result = ExtractionResult()

    principled = find_principled(material)
    if principled is None:
        result.warnings.append("No Principled BSDF found in this material")
        return result

    _extract_base_color(principled, result)
    _extract_normal_and_height(principled, result)
    _extract_scalar(principled, "Roughness", "roughness", result)
    _extract_scalar(principled, "Metallic", "metallic", result)
    _collapse_packed_orm(principled, result)

    if "Emission Color" in principled.inputs:
        _extract_simple(principled, "Emission Color", "emissive", result)
    _extract_simple(principled, "Alpha", "opacity", result)

    _extract_physical_size(material, result)

    # An image wired into several inputs is almost always a packed ORM the
    # artist split by hand, or a mistake. Either way the artist should know.
    seen: dict[str, str] = {}
    for role, image in result.images.items():
        if image is None:
            continue
        if image.name in seen:
            result.warnings.append(
                f"'{image.name}' feeds both {seen[image.name]} and {role}"
            )
        seen[image.name] = role

    return result
