"""Baking node work into images.

Single responsibility: turn what a node tree computes for one Principled input
into the image the library can carry. Knows nothing about manifests, files or
the panel.

The library carries images and a few numbers, not node trees: Godot rebuilds a
material from its maps alone. A base colour made of a wear mask blending two
paints, a roughness map passed through a contrast node, a metalness derived
from an alpha channel are all real work the artist sees in the viewport and
which exists nowhere but in the nodes. Read as plain images, such a material
comes out of the library looking like something else. Baked, it comes out as
it was authored.

The bake is an emission bake: the value entering the Principled is rendered as
light, on a flat square whose UVs cover one tile, so neither the scene's
lighting nor the model's own UVs take part in the result.
"""

from __future__ import annotations

import bpy
import numpy as np

from . import map_extractor

_IMAGE = "ShaderNodeTexImage"
_MAPPING = "ShaderNodeMapping"

# Used when the tree holds no image to take a size from (a fully procedural material).
_DEFAULT_SIZE = 1024

# Several samples per pixel: Cycles jitters them inside the pixel, and one alone
# leaves a visible grain on a detailed texture.
_SAMPLES = 4

# Under this spread (one step of an 8-bit channel), a baked map says one thing
# everywhere: it is published as a number, not as an image.
_UNIFORM_SPREAD = 1.0 / 255.0

# The roles published in colour; the others are data.
_COLOUR_ROLES = frozenset({"albedo"})


class BakeError(RuntimeError):
    """Raised when the node work cannot be baked."""


def bake_size(material: bpy.types.Material) -> tuple[int, int]:
    """The size to bake at: that of the largest image the tree reads, so the baked
    maps line up with the ones published as they are."""
    best = (0, 0)
    for node in material.node_tree.nodes:
        if node.bl_idname != _IMAGE or node.image is None:
            continue
        width, height = node.image.size
        if width * height > best[0] * best[1]:
            best = (width, height)
    return best if best[0] > 0 else (_DEFAULT_SIZE, _DEFAULT_SIZE)


def _unit_square(name: str) -> bpy.types.Object:
    """A flat square whose UVs cover exactly one tile."""
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)], [], [(0, 1, 2, 3)])
    layer = mesh.uv_layers.new(name="UVMap")
    for loop, uv in zip(layer.data, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop.uv = uv
    return bpy.data.objects.new(name, mesh)


def _output_node(tree: bpy.types.NodeTree) -> bpy.types.Node:
    output = tree.get_output_node("CYCLES") or tree.get_output_node("ALL")
    if output is None:
        raise BakeError("The material has no Material Output to bake through")
    return output


class _Stage:
    """Everything a bake borrows from the artist's file, given back on exit.

    The scene's render settings, the selection, the material's own output link
    and the Mapping node's scale are all changed for the time of the bake. The
    Mapping scale is the tile size, which the manifest carries on its own: baked
    with it, the image would hold several tiles and be tiled again in Godot.
    """

    def __init__(self, context, material: bpy.types.Material, size: tuple[int, int]):
        self.context = context
        self.material = material
        self.size = size
        self.tree = material.node_tree
        self.scene = context.scene
        self.view_layer = context.view_layer

    def __enter__(self) -> "_Stage":
        scene, tree = self.scene, self.tree
        self.output = _output_node(tree)
        surface = self.output.inputs["Surface"]
        self._surface_source = surface.links[0].from_socket if surface.is_linked else None
        self._active_node = tree.nodes.active
        self._settings = [(scene.render, "engine", scene.render.engine)]
        scene.render.engine = "CYCLES"
        for owner, name, value in (
            (scene.cycles, "samples", _SAMPLES),
            (scene.cycles, "bake_type", "EMIT"),
            (scene.render.bake, "use_clear", True),
            (scene.render.bake, "margin", 0),
            (scene.render.bake, "use_selected_to_active", False),
            (scene.render.bake, "target", "IMAGE_TEXTURES"),
        ):
            self._settings.append((owner, name, getattr(owner, name)))
            setattr(owner, name, value)

        self._mapping_scales = []
        for node in tree.nodes:
            if node.bl_idname == _MAPPING:
                scale = node.inputs["Scale"]
                self._mapping_scales.append((scale, tuple(scale.default_value)))
                scale.default_value = (1.0, 1.0, 1.0)
                break

        # An image of the baked size is read texel for texel: left on Linear, the
        # samples Cycles spreads inside each pixel would blur it into its neighbours.
        self._interpolations = []
        for node in tree.nodes:
            if node.bl_idname == _IMAGE and node.image is not None and tuple(node.image.size) == tuple(self.size):
                self._interpolations.append((node, node.interpolation))
                node.interpolation = "Closest"

        self._selected = [obj for obj in self.view_layer.objects if obj.select_get()]
        self._active_object = self.view_layer.objects.active
        for obj in self._selected:
            obj.select_set(False)
        self.square = _unit_square("ds_bake_square")
        self.square.data.materials.append(self.material)
        scene.collection.objects.link(self.square)
        self.square.select_set(True)
        self.view_layer.objects.active = self.square

        self.emission = tree.nodes.new("ShaderNodeEmission")
        self.target = tree.nodes.new(_IMAGE)
        tree.links.new(self.emission.outputs[0], surface)
        tree.nodes.active = self.target
        return self

    def __exit__(self, *_) -> None:
        tree = self.tree
        tree.nodes.remove(self.emission)
        tree.nodes.remove(self.target)
        if self._surface_source is not None:
            tree.links.new(self._surface_source, self.output.inputs["Surface"])
        tree.nodes.active = self._active_node

        mesh = self.square.data
        bpy.data.objects.remove(self.square)
        bpy.data.meshes.remove(mesh)
        for obj in self._selected:
            obj.select_set(True)
        self.view_layer.objects.active = self._active_object

        for scale, value in self._mapping_scales:
            scale.default_value = value
        for node, interpolation in self._interpolations:
            node.interpolation = interpolation
        # The engine last: the Cycles settings are restored while it is still the engine.
        for owner, name, value in reversed(self._settings):
            setattr(owner, name, value)

    def bake(self, source_socket, name: str, colour: bool) -> bpy.types.Image:
        """Render what leaves source_socket into a new image."""
        image = bpy.data.images.new(name, self.size[0], self.size[1], alpha=False)
        # The colour space first: changing it afterwards regenerates the image, blank.
        image.colorspace_settings.name = "sRGB" if colour else "Non-Color"
        self.target.image = image
        self.tree.links.new(source_socket, self.emission.inputs["Color"])
        try:
            outcome = bpy.ops.object.bake(type="EMIT")
        except RuntimeError as error:
            bpy.data.images.remove(image)
            raise BakeError(f"Baking {name} failed: {error}") from error
        if outcome != {"FINISHED"}:
            bpy.data.images.remove(image)
            raise BakeError(f"Baking {name} did not finish")
        return image


def _uniform_value(image: bpy.types.Image) -> tuple[float, float, float] | None:
    """The one colour of an image that holds a single one, else None."""
    pixels = np.empty(image.size[0] * image.size[1] * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    channels = pixels.reshape(-1, 4)[:, :3]
    low, high = channels.min(axis=0), channels.max(axis=0)
    if float((high - low).max()) > _UNIFORM_SPREAD:
        return None
    return tuple(round(float(value), 4) for value in (low + high) / 2.0)


def resolve(context, material: bpy.types.Material, result: map_extractor.ExtractionResult) -> list:
    """Bake every role the extraction left to the baker, and file each where it belongs.

    A baked map that varies joins result.images, as if the artist had wired
    that image. One that says the same thing everywhere is published as the
    number it is: albedo_color, roughness or metallic.

    Returns the images created, for the caller to remove once they are written.

    Raises:
        BakeError: when Blender cannot bake here and now.
    """
    if not result.bake:
        return []
    if context.mode != "OBJECT":
        raise BakeError(
            "This material's node work has to be baked, which Blender only does in Object Mode: "
            "leave the current mode and export again"
        )

    created: list = []
    try:
        with _Stage(context, material, bake_size(material)) as stage:
            for role, socket in result.bake.items():
                source = socket.links[0].from_socket
                colour = role in _COLOUR_ROLES
                image = stage.bake(source, f"ds_baked_{role}", colour)
                created.append(image)
                value = _uniform_value(image)
                if value is None:
                    result.images[role] = image
                elif colour:
                    # The pixels of an sRGB image are sRGB, as albedo_color is.
                    result.albedo_color = value
                else:
                    setattr(result, role, value[0])
    except BaseException:
        discard(created)
        raise
    result.bake = {}
    return created


def discard(images: list) -> None:
    """Remove the images a bake created, once they are written or given up on."""
    for image in images:
        try:
            bpy.data.images.remove(image)
        except ReferenceError:
            pass
    images.clear()
