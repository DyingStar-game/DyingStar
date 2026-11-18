"""The dyingstar_material_library addon end to end, in Blender without a window: enable it from this repository,
publish materials an artist could have made -- a plain colour with no map at all, an albedo alone, a normal map
alone, a colour picked in an RGB node, a colour under an occlusion map, a tinted texture -- and read every
export back; then link one of them, as a model does, and read what the panel says of it.

usage: blender -b --factory-startup --python tools/blender_scripts/test_material_library_addon.py -- \
           [<scratch folder>]
Prints "ADDON TEST OK" and exits 0, or the failure and exits 1. The project is only read: the add-on is pointed at
a copy of the few files it needs, in the scratch folder, and nothing is installed into Blender's own folders.
"""
import json
import os
import pathlib
import shutil
import sys
import tempfile
import traceback

import bpy
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
ADDON = "dyingstar_material_library"
MATERIALS = ("assets", "_universe", "_shared", "materials")
SIZE = 64  # a multiple of 4, as the library's rules ask


def _scratch_project(scratch):
    """A copy of what the add-on reads from the project: the shared rules and the tag vocabulary."""
    root = os.path.join(scratch, "project")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.join(root, *MATERIALS))
    os.makedirs(os.path.join(root, "tools", "schema"))
    shutil.copy(os.path.join(PROJECT, "tools", "map_rules.py"), os.path.join(root, "tools"))
    shutil.copy(os.path.join(PROJECT, "tools", "schema", "tags.json"), os.path.join(root, "tools", "schema"))
    return root


def _image(name, colour):
    """A map with something in it (a uniform one is reported as carrying nothing), with no file behind it."""
    image = bpy.data.images.new(name, SIZE, SIZE, alpha=False)
    # The colour space first: changing it afterwards regenerates the image, blank.
    image.colorspace_settings.name = "sRGB" if colour else "Non-Color"
    pixels = np.ones((SIZE * SIZE, 4), dtype=np.float32)
    pixels[:, :3] = np.random.default_rng(len(name)).random((SIZE * SIZE, 3), dtype=np.float32)
    image.pixels.foreach_set(pixels.ravel())
    return image


def _material(obj, name):
    """A new material on the object, with its Principled BSDF; the fields an export asks for are filled in."""
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    obj.active_material = material
    material.dyingstar.display_name = name
    material.dyingstar.author = "tester"
    material.dyingstar.tags.add().name = "metal"
    principled = next(n for n in material.node_tree.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled")
    return material, material.node_tree, principled


def _texture(tree, image):
    node = tree.nodes.new("ShaderNodeTexImage")
    node.image = image
    return node


def _multiply(tree):
    """A Mix node that multiplies its two colours in full."""
    node = tree.nodes.new("ShaderNodeMix")
    node.data_type = "RGBA"
    node.blend_type = "MULTIPLY"
    node.inputs["Factor"].default_value = 1.0
    return node


def _export(name):
    """Publish the active material and return (its manifest, its folder's file names)."""
    assert bpy.ops.dyingstar.export_material() == {"FINISHED"}, "export %s" % name
    folder = os.path.join(_export.materials_dir, name)
    with open(os.path.join(folder, "material.json"), encoding="utf-8") as handle:
        return json.load(handle), sorted(os.listdir(folder))


def _round_trip(manifest, extractor, builder):
    """The published material, rebuilt as the Asset Browser library builds it, reads back the same."""
    folder = pathlib.Path(_export.materials_dir, manifest["id"])
    rebuilt = builder.build_material(manifest, folder)
    result = extractor.extract(rebuilt)
    assert sorted(result.images) == sorted(manifest["maps"]), "%s: maps read back %s" % (
        manifest["id"], sorted(result.images))
    for value in ("roughness", "metallic"):
        if value in manifest:
            assert abs(getattr(result, value) - manifest[value]) < 1e-3, "%s: %s read back %s, published %s" % (
                manifest["id"], value, getattr(result, value), manifest[value])
    expected = manifest.get("albedo_color")
    if expected is not None:
        assert result.albedo_color is not None and np.allclose(result.albedo_color, expected, atol=1e-3), \
            "%s: colour read back %s, published %s" % (manifest["id"], result.albedo_color, expected)
    bpy.data.materials.remove(rebuilt)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    scratch = os.path.abspath(argv[0]) if argv else tempfile.mkdtemp(prefix="ds_material_library_")
    root = _scratch_project(scratch)
    _export.materials_dir = os.path.join(root, *MATERIALS)

    # The repository's copy, first on the path: an older one installed in Blender must not be the one tested.
    sys.path.insert(0, os.path.join(HERE, "addons"))
    sys.path.insert(0, os.path.join(PROJECT, "tools"))
    import addon_utils
    assert addon_utils.enable(ADDON, default_set=True) is not None, "enable the add-on"
    bpy.context.preferences.addons[ADDON].preferences.repository_root = root
    import dyingstar_material_library.map_extractor as extractor  # noqa: E402
    import material_builder as builder  # noqa: E402  (tools/material_builder.py: the library's own builder)
    assert os.path.normcase(extractor.__file__).startswith(os.path.normcase(HERE)), extractor.__file__

    obj = bpy.data.objects.new("probe", bpy.data.meshes.new("probe"))
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj

    # 1. A plain colour and nothing else: no map at all.
    name = "mat_metal_plain_grey"
    material, tree, principled = _material(obj, name)
    principled.inputs["Base Color"].default_value = (0.2, 0.2, 0.2, 1.0)
    assert bpy.ops.dyingstar.detect_material_maps() == {"FINISHED"}, "a material with no map is detected"
    manifest, files = _export(name)
    assert manifest["maps"] == {}, manifest["maps"]
    assert np.allclose(manifest["albedo_color"], [0.4845, 0.4845, 0.4845], atol=1e-3), manifest["albedo_color"]
    assert "alpha" not in manifest
    assert files == ["material.json", "preview.jpg"], files
    _round_trip(manifest, extractor, builder)

    # 2. An albedo and nothing else: no normal map.
    name = "mat_metal_albedo_only"
    material, tree, principled = _material(obj, name)
    tree.links.new(_texture(tree, _image("albedo", True)).outputs["Color"], principled.inputs["Base Color"])
    manifest, files = _export(name)
    assert manifest["maps"] == {"albedo": "tex_metal_albedo_only_albedo.png"}, manifest["maps"]
    assert "albedo_color" not in manifest
    assert files == ["material.json", "preview.jpg", "tex_metal_albedo_only_albedo.png"], files
    _round_trip(manifest, extractor, builder)

    # 3. A normal map and a plain colour: no albedo.
    name = "mat_metal_normal_only"
    material, tree, principled = _material(obj, name)
    principled.inputs["Base Color"].default_value = (1.0, 0.0, 0.0, 1.0)
    normal_map = tree.nodes.new("ShaderNodeNormalMap")
    tree.links.new(_texture(tree, _image("normal", False)).outputs["Color"], normal_map.inputs["Color"])
    tree.links.new(normal_map.outputs["Normal"], principled.inputs["Normal"])
    manifest, files = _export(name)
    assert manifest["maps"] == {"normal": "tex_metal_normal_only_normal.png"}, manifest["maps"]
    assert manifest["albedo_color"] == [1.0, 0.0, 0.0], manifest["albedo_color"]
    assert "preview.jpg" in files, "a plain colour has its swatch for a preview"
    _round_trip(manifest, extractor, builder)

    # 4. The colour picked in an RGB node: still a plain colour.
    name = "mat_metal_rgb_node"
    material, tree, principled = _material(obj, name)
    rgb = tree.nodes.new("ShaderNodeRGB")
    rgb.outputs[0].default_value = (0.0, 1.0, 0.0, 1.0)
    tree.links.new(rgb.outputs[0], principled.inputs["Base Color"])
    manifest, files = _export(name)
    assert manifest["maps"] == {} and manifest["albedo_color"] == [0.0, 1.0, 0.0], manifest
    _round_trip(manifest, extractor, builder)

    # 5. A plain colour under an occlusion map.
    name = "mat_metal_colour_ao"
    material, tree, principled = _material(obj, name)
    mix = tree.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.inputs["A"].default_value = (0.0, 0.0, 1.0, 1.0)
    tree.links.new(_texture(tree, _image("occlusion", False)).outputs["Color"], mix.inputs["B"])
    tree.links.new(mix.outputs["Result"], principled.inputs["Base Color"])
    manifest, files = _export(name)
    assert manifest["maps"] == {"ao": "tex_metal_colour_ao_ao.png"}, manifest["maps"]
    assert manifest["albedo_color"] == [0.0, 0.0, 1.0], manifest["albedo_color"]
    _round_trip(manifest, extractor, builder)

    # 6. A base colour the add-on cannot read is refused, and the refusal names the node.
    name = "mat_metal_colour_ramp"
    material, tree, principled = _material(obj, name)
    ramp = tree.nodes.new("ShaderNodeValToRGB")
    tree.links.new(ramp.outputs["Color"], principled.inputs["Base Color"])
    try:
        bpy.ops.dyingstar.export_material()
    except RuntimeError as error:  # an operator's ERROR report, as Python sees it
        assert "ShaderNodeValToRGB" in str(error), str(error)
    else:
        raise AssertionError("a base colour behind a ColorRamp was published")
    assert not os.path.exists(os.path.join(_export.materials_dir, name)), "and nothing was written"

    # 7. A texture multiplied by a flat colour is a tint: the albedo and albedo_color.
    name = "mat_metal_tinted"
    material, tree, principled = _material(obj, name)
    tint = _multiply(tree)
    tree.links.new(_texture(tree, _image("grey_albedo", True)).outputs["Color"], tint.inputs["A"])
    tint.inputs["B"].default_value = (1.0, 0.5, 0.25, 1.0)
    tree.links.new(tint.outputs["Result"], principled.inputs["Base Color"])
    manifest, files = _export(name)
    assert manifest["maps"] == {"albedo": "tex_metal_tinted_albedo.png"}, manifest["maps"]
    assert np.allclose(manifest["albedo_color"], [1.0, 0.7354, 0.5371], atol=2e-3), manifest["albedo_color"]
    _round_trip(manifest, extractor, builder)

    # 8. The same tinted texture under an occlusion map.
    name = "mat_metal_tinted_ao"
    material, tree, principled = _material(obj, name)
    tint = _multiply(tree)
    tree.links.new(_texture(tree, _image("grey_albedo_2", True)).outputs["Color"], tint.inputs["A"])
    tint.inputs["B"].default_value = (0.25, 0.5, 1.0, 1.0)
    shade = _multiply(tree)
    tree.links.new(tint.outputs["Result"], shade.inputs["A"])
    tree.links.new(_texture(tree, _image("occlusion_2", False)).outputs["Color"], shade.inputs["B"])
    tree.links.new(shade.outputs["Result"], principled.inputs["Base Color"])
    manifest, files = _export(name)
    assert sorted(manifest["maps"]) == ["albedo", "ao"], manifest["maps"]
    assert np.allclose(manifest["albedo_color"], [0.5371, 0.7354, 1.0], atol=2e-3), manifest["albedo_color"]
    _round_trip(manifest, extractor, builder)

    # 9. A colour laid over the texture any other way cannot be carried: it is said, not published.
    name = "mat_metal_half_mixed"
    material, tree, principled = _material(obj, name)
    blend = _multiply(tree)
    blend.inputs["Factor"].default_value = 0.5
    tree.links.new(_texture(tree, _image("grey_albedo_3", True)).outputs["Color"], blend.inputs["A"])
    blend.inputs["B"].default_value = (1.0, 0.0, 0.0, 1.0)
    tree.links.new(blend.outputs["Result"], principled.inputs["Base Color"])
    assert any("Multiply" in warning for warning in extractor.extract(material).warnings), "the way out is named"
    manifest, files = _export(name)
    assert "albedo_color" not in manifest, manifest

    # 9a. Two images blended by a factor are a layered colour, not an albedo and its occlusion.
    name = "mat_metal_layered"
    material, tree, principled = _material(obj, name)
    layers = _multiply(tree)
    layers.blend_type = "MIX"
    layers.inputs["Factor"].default_value = 0.5
    tree.links.new(_texture(tree, _image("paint", True)).outputs["Color"], layers.inputs["A"])
    tree.links.new(_texture(tree, _image("bare_metal", True)).outputs["Color"], layers.inputs["B"])
    tree.links.new(layers.outputs["Result"], principled.inputs["Base Color"])
    assert any("two images" in warning for warning in extractor.extract(material).warnings), "the blend is named"
    manifest, files = _export(name)
    assert sorted(manifest["maps"]) == ["albedo"], "the second image is not taken for an occlusion map"

    # 9b. The roughness and metallic set by hand travel as numbers; under a map, the map does.
    name = "mat_glass_screen_off"
    material, tree, principled = _material(obj, name)
    principled.inputs["Base Color"].default_value = (0.01, 0.01, 0.012, 1.0)
    principled.inputs["Roughness"].default_value = 0.077
    principled.inputs["Metallic"].default_value = 0.25
    manifest, files = _export(name)
    assert abs(manifest["roughness"] - 0.077) < 1e-4 and abs(manifest["metallic"] - 0.25) < 1e-4, manifest
    assert manifest["maps"] == {}, manifest["maps"]
    _round_trip(manifest, extractor, builder)
    name = "mat_metal_rough_mapped"
    material, tree, principled = _material(obj, name)
    tree.links.new(_texture(tree, _image("roughness_map", False)).outputs["Color"], principled.inputs["Roughness"])
    manifest, files = _export(name)
    assert "roughness" not in manifest and "roughness" in manifest["maps"], manifest
    assert manifest["metallic"] == 0.0, "the other one is still a value"
    _round_trip(manifest, extractor, builder)

    # 10. A material linked from the library is read-only: the panel shows what the library says of it,
    # and the buttons that would write to it are off.
    import dyingstar_material_library.ui as panel  # noqa: E402
    library_file = os.path.join(scratch, "library.blend")
    # The library file is generated without the add-on: its materials hold none of the panel's fields.
    published = bpy.data.materials["mat_metal_plain_grey"]
    published.dyingstar.display_name = ""
    published.dyingstar.author = ""
    published.dyingstar.tags.clear()
    bpy.data.libraries.write(library_file, {published})
    with bpy.data.libraries.load(library_file, link=True) as (source, target):
        target.materials = ["mat_metal_plain_grey"]
    linked = target.materials[0]
    assert linked.library is not None, "linked, not appended"
    obj.active_material = linked
    rows = dict(panel.linked_summary(linked))
    assert rows["Display Name"] == "mat_metal_plain_grey" and rows["Author"] == "tester", rows
    assert rows["Tags"] == "metal" and rows["License"] == "AGPL-3.0" and rows["Tile size"] == "1 m x 1 m", rows
    assert linked.dyingstar.display_name == "", "its own fields are empty, and cannot be filled"
    for operator in (bpy.ops.dyingstar.export_material, bpy.ops.dyingstar.detect_material_maps,
                     bpy.ops.dyingstar.load_material_from_library, bpy.ops.dyingstar.add_material_tag):
        assert not operator.poll(), "%s is off on a linked material" % operator.idname()
    obj.active_material = bpy.data.materials.new("mat_metal_local")
    assert bpy.ops.dyingstar.detect_material_maps.poll(), "and on again on a material of this file"

    print("ADDON TEST OK (%s)" % scratch)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - every failure is a failed test
        traceback.print_exc()
        sys.exit(1)
    sys.exit(0)
