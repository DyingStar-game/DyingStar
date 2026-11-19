"""Node tree analysis: work out which image plays which PBR role.

Single responsibility: given a material, walk backwards from the Principled
BSDF and report the image found behind each of its inputs. Knows nothing about
files, manifests or the UI.

Identification is by connection, not by file name. A file called
"Rough_02_final.png" wired into the Roughness input is the roughness map,
whatever the texturing tool decided to call it.

Only a wiring the manifest says in full is read as images and numbers. Any
other -- a mask blending two paints, a map passed through a contrast node -- is
node work, which exists nowhere but in the tree: the input is then left to the
baker (map_baker), named in ExtractionResult.bake.
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
_MATH = "ShaderNodeMath"
_RGB = "ShaderNodeRGB"

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
    # sRGB base colour of a Base Color left unlinked (a plain-coloured surface), else None
    albedo_color: tuple[float, float, float] | None = None
    # The Principled's own Roughness and Metallic, when no map is wired there: the
    # surface's value, which the manifest carries as a number. None under a map.
    roughness: float | None = None
    metallic: float | None = None
    # Whether the Principled Alpha is fed by an image (the albedo's own alpha or
    # an opacity map), and the mode and threshold the wiring suggests: a Greater
    # Than node is a scissor at its second value, a direct link a blend.
    alpha_linked: bool = False
    alpha_mode: str | None = None
    alpha_threshold: float | None = None
    # map role -> the Principled input whose node work no image and no number
    # says: to be baked into that map at export (map_baker).
    bake: dict = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def is_usable(self) -> bool:
        """A library material needs a base colour, read from an image or from a plain colour.

        Every map is optional: a painted panel is a colour and nothing else, and
        a surface with no normal map is simply smooth. What cannot be published
        is a base colour the walker could not read, since the material would
        come out of the library a different colour than it was authored.
        """
        return "albedo" in self.images or self.albedo_color is not None or "albedo" in self.bake


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


def _linear_to_srgb(channel: float) -> float:
    """Blender's colour sockets are linear; albedo_color is written in sRGB."""
    channel = min(max(float(channel), 0.0), 1.0)
    if channel <= 0.0031308:
        return channel * 12.92
    return 1.055 * channel ** (1.0 / 2.4) - 0.055


def _plain_colour(value) -> tuple[float, float, float]:
    """A colour socket's value as albedo_color: sRGB, as Godot reads it."""
    return tuple(round(_linear_to_srgb(channel), 4) for channel in tuple(value)[:3])


def _is_image(socket) -> bool:
    """Whether a socket is fed by an Image Texture node and nothing else."""
    node = _linked_node(socket)
    return node is not None and node.bl_idname == _IMAGE


def _is_image_or_channel(socket) -> bool:
    """An image wired as it is, or one of its channels split by a Separate Color node."""
    node = _linked_node(socket)
    if node is not None and node.bl_idname == _SEPARATE_COLOR:
        return _is_image(node.inputs["Color"])
    return _is_image(socket)


def _is_tint(node: bpy.types.Node) -> bool:
    """An image multiplied in full by a flat colour: the albedo and albedo_color."""
    base_input, modulation_input = _mix_inputs(node)
    modulation = node.inputs[modulation_input]
    if not _is_image(node.inputs[base_input]) or modulation.is_linked:
        return False
    return _is_full_multiply(node) or (
        getattr(node, "blend_type", "") == "MULTIPLY" and _is_white(modulation.default_value)
    )


def _base_colour_is_exact(socket) -> bool:
    """Whether the manifest says all of what feeds Base Color.

    It can say a plain colour, an image, an image multiplied by a flat colour,
    and any of those under an occlusion map multiplied over it. Whatever else
    the nodes do -- a mask blending two paints, a hue shift, a Color Ramp, an
    occlusion laid over a blend -- is work only a bake can carry.
    """
    node = _linked_node(socket)
    if node is None or node.bl_idname in (_RGB, _IMAGE):
        return True
    if node.bl_idname not in (_MIX, _MIX_LEGACY) or getattr(node, "data_type", "RGBA") != "RGBA":
        return False
    if _is_tint(node):
        return True

    base_input, modulation_input = _mix_inputs(node)
    factor = node.inputs.get("Factor") or node.inputs.get("Fac")
    occluded = (
        getattr(node, "blend_type", "") == "MULTIPLY"
        and (factor is None or not factor.is_linked)
        and _is_image_or_channel(node.inputs[modulation_input])
    )
    if not occluded:
        return False
    base_socket = node.inputs[base_input]
    base = _linked_node(base_socket)
    if base is None or _is_image(base_socket):
        return True
    return base.bl_idname in (_MIX, _MIX_LEGACY) and _is_tint(base)


def _extract_base_color(principled: bpy.types.Node, result: ExtractionResult) -> None:
    """Base Color may be a plain colour or an image, tinted or not, alone or under an AO multiply."""
    socket = principled.inputs["Base Color"]
    if not _base_colour_is_exact(socket):
        result.bake["albedo"] = socket
        return
    node = _linked_node(socket)

    if node is None:
        # A plain colour: written as albedo_color, no texture needed.
        result.albedo_color = _plain_colour(socket.default_value)
        return

    if node.bl_idname == _RGB:
        # The same plain colour, picked in a node of its own.
        result.albedo_color = _plain_colour(node.outputs[0].default_value)
        return

    if node.bl_idname == _IMAGE:
        result.images["albedo"] = node.image
        return

    if node.bl_idname in (_MIX, _MIX_LEGACY):
        base_input, modulation_input = _mix_inputs(node)
        occlusion = _walk_to_image(node.inputs[modulation_input])
        if occlusion is None:
            # No occlusion map in B: the albedo in A, tinted or not by the colour in B.
            _extract_tinted_albedo(node, result)
            return

        # Occlusion in B, multiplied over what is in A: the albedo, itself tinted
        # or not (a Mix of its own, as material_builder wires it), or a plain colour.
        base = _linked_node(node.inputs[base_input])
        if base is not None and base.bl_idname in (_MIX, _MIX_LEGACY):
            _extract_tinted_albedo(base, result)
        else:
            _extract_tinted_albedo(node, result, tinted=False)
        if occlusion.image != result.images.get("albedo"):
            result.images["ao"] = occlusion.image


def _mix_inputs(node: bpy.types.Node) -> tuple[str, str]:
    """The names of a Mix node's two colour inputs: the base, then what modulates it."""
    return ("A", "B") if "A" in node.inputs else ("Color1", "Color2")


def _is_full_multiply(node: bpy.types.Node) -> bool:
    """Whether a Mix node multiplies its two colours in full, which is what Godot does
    with an albedo map and albedo_color: the one tint the manifest can carry."""
    factor = node.inputs.get("Factor") or node.inputs.get("Fac")
    return (
        getattr(node, "blend_type", "") == "MULTIPLY"
        and factor is not None
        and not factor.is_linked
        and abs(float(factor.default_value) - 1.0) < 1e-4
    )


def _extract_tinted_albedo(mix: bpy.types.Node, result: ExtractionResult, tinted: bool = True) -> None:
    """Read the base colour out of a Mix node: its first input, then its second as a tint.

    A is the albedo image, or a plain colour when nothing is wired there. With
    tinted, B is a flat colour laid over it: multiplied in full, it is published
    as albedo_color, which Godot multiplies over the albedo map the same way --
    one grey texture then gives every colour of a surface, with no new image.
    Only the wirings _base_colour_is_exact accepts reach this point.
    """
    base_input, modulation_input = _mix_inputs(mix)
    base_socket = mix.inputs[base_input]
    albedo = _walk_to_image(base_socket)

    if albedo is None:
        # A plain colour under an occlusion map: what material_builder wires
        # for a manifest with albedo_color, an ao map and no albedo.
        result.albedo_color = _plain_colour(base_socket.default_value)
        return

    result.images["albedo"] = albedo.image
    if not tinted:
        return
    tint_socket = mix.inputs[modulation_input]
    if not tint_socket.is_linked and not _is_white(tint_socket.default_value):
        result.albedo_color = _plain_colour(tint_socket.default_value)


def _is_white(value) -> bool:
    return all(round(float(channel), 3) == 1.0 for channel in tuple(value)[:3])


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
    """Roughness and metallic: an image, possibly via an ORM channel split, or the value set by hand."""
    socket = principled.inputs[input_name]
    if socket.is_linked and not _is_image_or_channel(socket):
        # A map reshaped on its way in (contrast, range, a mask's alpha): node work.
        result.bake[map_name] = socket
        return
    node = _walk_to_image(socket)
    if node is not None:
        result.images[map_name] = node.image
    elif not socket.is_linked:
        # Set by hand: without it, the material would come back from the library
        # with the default, and a polished surface would turn matte.
        setattr(result, map_name, round(float(socket.default_value), 4))


def _extract_simple(
    principled: bpy.types.Node,
    input_name: str,
    map_name: str,
    result: ExtractionResult,
) -> None:
    node = _linked_node(principled.inputs.get(input_name))
    if node is not None and node.bl_idname == _IMAGE:
        result.images[map_name] = node.image


def _extract_alpha(principled: bpy.types.Node, result: ExtractionResult) -> None:
    """The image behind the Alpha input, and whether it is cut at a threshold.

    Read after the base colour: an Alpha wired from the albedo image itself is
    already in the published albedo, so only another image is an opacity map
    (which the export packs into the albedo's alpha).
    """
    socket = principled.inputs.get("Alpha")
    node = _linked_node(socket) if socket is not None else None
    if node is None:
        return

    threshold = None
    if node.bl_idname == _MATH:
        if node.operation != "GREATER_THAN" or node.inputs[1].is_linked:
            result.warnings.append(
                "Alpha goes through a Math node that is not 'Greater Than' a fixed "
                "threshold, which the library cannot carry"
            )
            return
        threshold = round(float(node.inputs[1].default_value), 4)
        node = _linked_node(node.inputs[0])
        if node is None:
            return

    if node.bl_idname != _IMAGE:
        result.warnings.append(f"Alpha goes through an unsupported node ({node.bl_idname})")
        return

    result.alpha_linked = True
    result.alpha_mode = "SCISSOR" if threshold is not None else "BLEND"
    result.alpha_threshold = threshold
    # == rather than "is": bpy may hand out two wrappers of one datablock.
    if node.image is not None and node.image != result.images.get("albedo"):
        result.images["opacity"] = node.image


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
    _extract_alpha(principled, result)

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
