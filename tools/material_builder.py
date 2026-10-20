"""Principled BSDF node tree construction from a material manifest.

Single responsibility: given a parsed material.json and the folder holding its
maps, produce a correctly wired bpy Material. Knows nothing about the Asset
Browser, catalogs, file scanning or the CLI.

Requires Blender 4.0 or above: input names ("Emission Color") and the mix node
type (ShaderNodeMix) both changed in 4.0.
"""

from __future__ import annotations

from pathlib import Path

import bpy

# --- Configuration -----------------------------------------------------------

# Colour data must be interpreted as sRGB; everything else is raw data and must
# not go through gamma decoding. Getting this wrong is invisible on a thumbnail
# and very visible in a render.
SRGB_MAPS = frozenset({"albedo", "emissive"})

# Node layout, in Blender node-editor units. Only affects readability when an
# artist opens the shader graph.
COLUMN_WIDTH = 320
ROW_HEIGHT = 300

_MAP_ROW_ORDER = (
    "albedo",
    "ao",
    "orm",
    "roughness",
    "metallic",
    "normal",
    "height",
    "emissive",
    "opacity",
)


class MaterialBuildError(RuntimeError):
    """Raised when a manifest cannot be turned into a usable material."""


# --- Node helpers ------------------------------------------------------------


def _load_image(path: Path, is_color: bool) -> bpy.types.Image:
    """Load a map and force its colour space, whatever the file claims."""
    if not path.is_file():
        raise MaterialBuildError(f"map file not found: {path}")

    image = bpy.data.images.load(str(path), check_existing=True)
    image.colorspace_settings.name = "sRGB" if is_color else "Non-Color"
    return image


def _create_texture_nodes(
    node_tree: bpy.types.NodeTree,
    folder: Path,
    maps: dict[str, str],
) -> dict[str, bpy.types.Node]:
    """One Image Texture node per declared map, laid out in a readable column."""
    nodes: dict[str, bpy.types.Node] = {}
    ordered = [name for name in _MAP_ROW_ORDER if name in maps]

    for row, name in enumerate(ordered):
        node = node_tree.nodes.new("ShaderNodeTexImage")
        node.image = _load_image(folder / maps[name], is_color=name in SRGB_MAPS)
        node.label = name
        node.name = f"tex_{name}"
        node.location = (-2 * COLUMN_WIDTH, -row * ROW_HEIGHT)
        nodes[name] = node

    return nodes


def _create_uv_scaling(
    node_tree: bpy.types.NodeTree,
    texture_nodes: dict[str, bpy.types.Node],
    physical_size_m: list[float],
) -> None:
    """Drive every texture through one Mapping node.

    physical_size_m is the real-world size covered by one UV tile, so the tiling
    factor is its inverse. Centralising it here is what keeps scale consistent
    across the whole game world.
    """
    coordinates = node_tree.nodes.new("ShaderNodeTexCoord")
    coordinates.location = (-4 * COLUMN_WIDTH, 0)

    mapping = node_tree.nodes.new("ShaderNodeMapping")
    mapping.label = "Tiling"
    mapping.location = (-3 * COLUMN_WIDTH, 0)

    width, height = physical_size_m
    mapping.inputs["Scale"].default_value = (1.0 / width, 1.0 / height, 1.0)

    node_tree.links.new(coordinates.outputs["UV"], mapping.inputs["Vector"])
    for node in texture_nodes.values():
        node_tree.links.new(mapping.outputs["Vector"], node.inputs["Vector"])


def _unpack_orm(
    node_tree: bpy.types.NodeTree,
    orm_node: bpy.types.Node,
) -> dict[str, tuple[bpy.types.Node, str]]:
    """Split a packed ORM texture back into its three scalar channels."""
    separate = node_tree.nodes.new("ShaderNodeSeparateColor")
    separate.label = "ORM"
    separate.location = (-COLUMN_WIDTH, orm_node.location.y)
    node_tree.links.new(orm_node.outputs["Color"], separate.inputs["Color"])

    return {
        "ao": (separate, "Red"),
        "roughness": (separate, "Green"),
        "metallic": (separate, "Blue"),
    }


def _resolve_scalar_sources(
    node_tree: bpy.types.NodeTree,
    texture_nodes: dict[str, bpy.types.Node],
) -> dict[str, tuple[bpy.types.Node, str]]:
    """Return where ao, roughness and metallic come from, packed or not.

    The rest of the builder then works against a single interface and does not
    care which form the material uses.
    """
    if "orm" in texture_nodes:
        return _unpack_orm(node_tree, texture_nodes["orm"])

    return {
        name: (texture_nodes[name], "Color")
        for name in ("ao", "roughness", "metallic")
        if name in texture_nodes
    }


def _srgb_to_linear(channel: float) -> float:
    """Blender's colour sockets are linear; albedo_color is written in sRGB, as Godot reads it."""
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def _base_color_source(
    node_tree: bpy.types.NodeTree,
    principled: bpy.types.Node,
    albedo_node: bpy.types.Node | None,
    albedo_color: list[float] | None,
) -> bpy.types.NodeSocket | None:
    """The base colour as a socket: the albedo map, tinted by albedo_color when both are given.

    A plain-coloured material (albedo_color, no map) has no socket: its colour is set on the
    Principled input itself, and None is returned.
    """
    colour = None
    if albedo_color is not None:
        colour = (*(_srgb_to_linear(float(c)) for c in albedo_color), 1.0)
    if albedo_node is None:
        if colour is not None:
            principled.inputs["Base Color"].default_value = colour
        return None
    if colour is None:
        return albedo_node.outputs["Color"]
    tint = node_tree.nodes.new("ShaderNodeMix")
    tint.data_type = "RGBA"
    tint.blend_type = "MULTIPLY"
    tint.label = "Albedo x albedo_color"
    tint.location = (-COLUMN_WIDTH * 1.5, albedo_node.location.y)
    tint.inputs["Factor"].default_value = 1.0
    node_tree.links.new(albedo_node.outputs["Color"], tint.inputs["A"])
    tint.inputs["B"].default_value = colour
    return tint.outputs["Result"]


def _connect_base_color(
    node_tree: bpy.types.NodeTree,
    principled: bpy.types.Node,
    albedo_node: bpy.types.Node | None,
    ao_source: tuple[bpy.types.Node, str] | None,
    albedo_color: list[float] | None = None,
) -> None:
    """Wire albedo (tinted by albedo_color, or that colour alone), multiplying ambient occlusion
    into it when available.

    Trade-off worth knowing: Godot applies AO to ambient light only, while
    multiplying it into base colour darkens direct light too. It is the usual
    look-dev approximation, not a physically exact match. Set the Mix factor to
    0 in the shader graph to compare.
    """
    base = _base_color_source(node_tree, principled, albedo_node, albedo_color)
    if ao_source is None:
        if base is not None:
            node_tree.links.new(base, principled.inputs["Base Color"])
        return

    mix = node_tree.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.label = "Albedo x AO"
    mix.location = (-COLUMN_WIDTH, albedo_node.location.y if albedo_node is not None else 0)
    mix.inputs["Factor"].default_value = 1.0

    ao_node, ao_output = ao_source
    if base is not None:
        node_tree.links.new(base, mix.inputs["A"])
    else:
        mix.inputs["A"].default_value = principled.inputs["Base Color"].default_value
    node_tree.links.new(ao_node.outputs[ao_output], mix.inputs["B"])
    node_tree.links.new(mix.outputs["Result"], principled.inputs["Base Color"])


def _connect_surface_normal(
    node_tree: bpy.types.NodeTree,
    principled: bpy.types.Node,
    texture_nodes: dict[str, bpy.types.Node],
) -> None:
    """Chain the normal map, then the height map as a bump on top of it."""
    normal_node = texture_nodes.get("normal")
    height_node = texture_nodes.get("height")

    normal_output = None
    if normal_node is not None:
        normal_map = node_tree.nodes.new("ShaderNodeNormalMap")
        normal_map.location = (-COLUMN_WIDTH, normal_node.location.y)
        node_tree.links.new(normal_node.outputs["Color"], normal_map.inputs["Color"])
        normal_output = normal_map.outputs["Normal"]

    if height_node is not None:
        bump = node_tree.nodes.new("ShaderNodeBump")
        bump.location = (-COLUMN_WIDTH, height_node.location.y)
        node_tree.links.new(height_node.outputs["Color"], bump.inputs["Height"])
        if normal_output is not None:
            node_tree.links.new(normal_output, bump.inputs["Normal"])
        normal_output = bump.outputs["Normal"]

    if normal_output is not None:
        node_tree.links.new(normal_output, principled.inputs["Normal"])


def _connect_scalar_inputs(
    node_tree: bpy.types.NodeTree,
    principled: bpy.types.Node,
    scalar_sources: dict[str, tuple[bpy.types.Node, str]],
) -> None:
    for map_name, input_name in (("roughness", "Roughness"), ("metallic", "Metallic")):
        source = scalar_sources.get(map_name)
        if source is not None:
            node, output = source
            node_tree.links.new(node.outputs[output], principled.inputs[input_name])


def _connect_emission(
    node_tree: bpy.types.NodeTree,
    principled: bpy.types.Node,
    texture_nodes: dict[str, bpy.types.Node],
) -> None:
    emissive = texture_nodes.get("emissive")
    if emissive is None:
        return

    node_tree.links.new(emissive.outputs["Color"], principled.inputs["Emission Color"])
    principled.inputs["Emission Strength"].default_value = 1.0


def _connect_alpha(
    material: bpy.types.Material,
    node_tree: bpy.types.NodeTree,
    principled: bpy.types.Node,
    texture_nodes: dict[str, bpy.types.Node],
    alpha: dict | None,
) -> None:
    """Drive the Principled Alpha the way Godot reads the manifest's alpha block.

    The transparency is the albedo map's own alpha, where the add-on packs the
    opacity at export. A manifest that still lists a standalone opacity map
    predates that packing: its map is wired as before, so it keeps its look here.

    scissor goes through a Greater Than node at the threshold, a hard edge like
    Godot's alpha scissor, and map_extractor reads that node back as a scissor.
    """
    opacity = texture_nodes.get("opacity")
    albedo = texture_nodes.get("albedo")
    if opacity is not None:
        source = opacity.outputs["Color"]
    elif alpha is not None and albedo is not None:
        source = albedo.outputs["Alpha"]
    else:
        return

    # An opacity map without an alpha block keeps the blended look it always had.
    mode = (alpha or {}).get("mode", "blend")
    if mode == "scissor":
        cut = node_tree.nodes.new("ShaderNodeMath")
        cut.operation = "GREATER_THAN"
        cut.label = "Alpha scissor"
        cut.location = (-COLUMN_WIDTH, -len(texture_nodes) * ROW_HEIGHT)
        cut.inputs[1].default_value = float(alpha.get("threshold", 0.5))
        node_tree.links.new(source, cut.inputs[0])
        source = cut.outputs["Value"]
    node_tree.links.new(source, principled.inputs["Alpha"])

    # The render method moved in Blender 4.2 (EEVEE Next). Guard both. Dithered
    # renders the already hard-edged scissor alpha as a clean cut, as Clip did.
    if hasattr(material, "surface_render_method"):
        material.surface_render_method = "DITHERED" if mode == "scissor" else "BLENDED"
    elif hasattr(material, "blend_method"):
        material.blend_method = "CLIP" if mode == "scissor" else "BLEND"


# --- Entry point -------------------------------------------------------------


def build_material(manifest: dict, folder: Path) -> bpy.types.Material:
    """Create and wire a material from its manifest.

    Args:
        manifest: parsed material.json.
        folder: directory holding the map files.

    Returns:
        The created material, not yet marked as an asset.

    Raises:
        MaterialBuildError: when a declared map file is missing.
    """
    material = bpy.data.materials.new(name=manifest["id"])
    material.use_nodes = True

    node_tree = material.node_tree
    node_tree.nodes.clear()

    output = node_tree.nodes.new("ShaderNodeOutputMaterial")
    output.location = (COLUMN_WIDTH, 0)

    principled = node_tree.nodes.new("ShaderNodeBsdfPrincipled")
    principled.location = (0, 0)
    node_tree.links.new(principled.outputs["BSDF"], output.inputs["Surface"])

    maps = manifest["maps"]
    texture_nodes = _create_texture_nodes(node_tree, folder, maps)
    _create_uv_scaling(node_tree, texture_nodes, manifest["physical_size_m"])

    scalar_sources = _resolve_scalar_sources(node_tree, texture_nodes)

    _connect_base_color(
        node_tree,
        principled,
        texture_nodes.get("albedo"),
        scalar_sources.get("ao"),
        manifest.get("albedo_color"),
    )
    _connect_scalar_inputs(node_tree, principled, scalar_sources)
    _connect_surface_normal(node_tree, principled, texture_nodes)
    _connect_emission(node_tree, principled, texture_nodes)
    _connect_alpha(material, node_tree, principled, texture_nodes, manifest.get("alpha"))

    return material
