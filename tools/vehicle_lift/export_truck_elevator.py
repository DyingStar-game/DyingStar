"""Export the truck elevator model (truck_elevator_A.blend) to the GLB pieces the VehicleLift model
"truck_elevator" is built from (scenes/_universe/structures/industrial/truck_elevator/).

Run headless, the .blend first; it is opened, never saved:

    blender -b <path>/truck_elevator_A.blend --python tools/vehicle_lift/export_truck_elevator.py

Each piece is one or more collections of the .blend, baked as they render (modifiers, geometry-nodes instances)
into the lift's frame: origin on the face of the rails, at the platform's deck (or the piece's top), the platform
towards +Z in Godot (the old lift's convention). Three meshes per GLB:
- "Shell": the concrete, the rails, the road, everything seen from afar;
- "Detail": ladders, bolts, ladder landings (the scenes hide it past a few tens of metres);
- "Collision-colonly": the walkable/drivable surfaces, which Godot imports as a static trimesh body.

Materials follow the wiki's "Materials" page: a material the shared library has is replaced by the library's
(linked from materials_library.blend) and exported by name only (Materials: Export, Images: None), so Godot's
post_import_shared_materials.gd assigns its .tres; the others leave as flat colours of the model (their textures
are not in the project).
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "assets/_universe/structures/industrial/truck_elevator"
LIBRARY = ROOT / "assets_blender/_universe/_shared/materials/materials_library.blend"
CREDIT = "Discord - Kankan - 415122592337362944\n"

# The face of the rails (Blender y) and the platform's deck at the top and at the bottom (Blender z).
RAIL_FACE_Y = -11.86
TOP_DECK_Z = 42.94
BOTTOM_DECK_Z = 2.17

# piece -> collections, the height of its origin, the objects that make its collision mesh[, objects left out[,
# the only objects kept]].
PIECES = {
    "top": (["segment top", "call"], TOP_DECK_Z, r"^(segment top|road|stairs&ramp|pavement)"),
    "section": (["intermediate section"], 21.47, None),
    "base": (["base section"], BOTTOM_DECK_Z, r"^base\.001$"),
    "pit": (["bottom section", "call2"], BOTTOM_DECK_Z, r"^(fosse|pavement)"),
    # Without its front ramp: a piece of its own, which folds up while the lift runs (the "ramp" piece).
    "platform": (["elevator"], TOP_DECK_Z, None, r"^ramp"),
    # The platform's front ramp alone, in the platform's frame: it folds up while the lift runs (truck_elevator_ramp.gd).
    "ramp": (["elevator"], TOP_DECK_Z, None, None, r"^ramp"),
    # The call kiosk alone (no pavement, no bollards), in the top's frame: the stop landings stand it on their deck.
    "kiosk": (["call"], TOP_DECK_Z, None, r"^(pavement|protection)"),
}
# Seen only up close: the scenes hide these past a few tens of metres.
DETAIL = re.compile(r"ladder|^vis\.|stage fiished|bolt|holder|button|cable", re.IGNORECASE)

# The model's material -> the shared library's (wiki "Materials", flow 2).
SHARED = {
    "yellow metal": "mat_metal_yellow_hauling",
    "Couleur Hauling": "mat_metal_yellow_hauling",
    "Material.001": "mat_concrete_wall_smooth",
    "béton": "mat_concrete_wall_smooth",
    "DiamondPlate009_1K-JPG_NORMAL.004": "mat_metal_diamondplate2k",
    "mat_metal_diamondplate2k": "mat_metal_diamondplate2k",
}
# Faces with no material are the concrete of the tower.
NO_MATERIAL = "mat_concrete_wall_smooth"
# The model's own materials (flow 1), as flat colours: name -> (base colour, metallic, roughness).
FLAT = {
    "GalvanizedZinc_7184_1K": ("truck_elevator_galvanized", (0.56, 0.57, 0.58), 0.9, 0.45),
    "Antracite.001": ("truck_elevator_anthracite", (0.05, 0.05, 0.055), 0.3, 0.6),
    "Gris.001": ("truck_elevator_grey", (0.35, 0.35, 0.36), 0.2, 0.6),
    "Matériau.002": ("truck_elevator_grey", (0.35, 0.35, 0.36), 0.2, 0.6),
    "asphalt": ("truck_elevator_asphalt", (0.07, 0.07, 0.07), 0.0, 0.92),
}

# Turn half a turn about Z (the platform then leaves towards +Z once glTF makes Y up), after moving the origin.
HALF_TURN = Matrix.Rotation(math.pi, 4, "Z")


def shared_material(name: str) -> bpy.types.Material:
    material = bpy.data.materials.get(name)
    if material is not None and material.library is not None:
        return material
    with bpy.data.libraries.load(str(LIBRARY), link=True) as (source, target):
        if name not in source.materials:
            raise SystemExit("%s is not in %s" % (name, LIBRARY))
        target.materials = [name]
    return target.materials[0]


def flat_material(spec: tuple) -> bpy.types.Material:
    name, colour, metallic, roughness = spec
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    if not material.node_tree:
        material.use_nodes = True
    bsdf = material.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*colour, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return material


def export_material(material: bpy.types.Material | None) -> bpy.types.Material:
    if material is None:
        return shared_material(NO_MATERIAL)
    if material.name in SHARED:
        return shared_material(SHARED[material.name])
    if material.name.startswith("mat_"):
        return shared_material(material.name)
    if material.name in FLAT:
        return flat_material(FLAT[material.name])
    print("[truck_elevator] unknown material %r kept as grey" % material.name)
    return flat_material(FLAT["Gris.001"])


def piece_objects(collections: list[str]) -> set:
    found = set()
    for name in collections:
        found.update(bpy.data.collections[name].all_objects)
    return found


def baked(objects: set, frame: Matrix) -> list[tuple[str, bpy.types.Mesh]]:
    """Every mesh the depsgraph draws for these objects (instances included), in the lift's frame."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    out = []
    for instance in depsgraph.object_instances:
        owner = (instance.parent if instance.is_instance else instance.object).original
        if owner not in objects or instance.object.type != "MESH":
            continue
        mesh = bpy.data.meshes.new_from_object(instance.object, preserve_all_data_layers=False, depsgraph=depsgraph)
        if len(mesh.polygons) == 0:
            bpy.data.meshes.remove(mesh)
            continue
        matrix = frame @ instance.matrix_world
        mesh.transform(matrix)
        if matrix.determinant() < 0.0:
            # A mirrored object (scale -1, as the tower's section and top are): its faces would turn inside out, and
            # Godot culls back faces. Blender draws both sides, so it never showed.
            mesh.flip_normals()
        if mesh.uv_layers:
            mesh.uv_layers[0].name = "UVMap"
            while len(mesh.uv_layers) > 1:
                mesh.uv_layers.remove(mesh.uv_layers[1])
        for index, material in enumerate(mesh.materials):
            mesh.materials[index] = export_material(material)
        if len(mesh.materials) == 0:
            mesh.materials.append(export_material(None))
        out.append((owner.name, mesh))
    return out


def joined(name: str, meshes: list[bpy.types.Mesh], collection: bpy.types.Collection) -> bpy.types.Object | None:
    if not meshes:
        return None
    objects = []
    for mesh in meshes:
        obj = bpy.data.objects.new(name, mesh)
        collection.objects.link(obj)
        objects.append(obj)
    with bpy.context.temp_override(active_object=objects[0], selected_editable_objects=objects,
            selected_objects=objects):
        bpy.ops.object.join()
    result = objects[0]
    result.name = name
    result.data.name = name
    return result


def export_piece(source: bpy.types.Scene, piece: str, collections: list[str], origin_z: float,
        collide: str | None, exclude: str | None = None, only: str | None = None) -> None:
    frame = HALF_TURN @ Matrix.Translation(Vector((0.0, -RAIL_FACE_Y, -origin_z)))
    # Baked from the model's scene: the window shows the last export's scene otherwise.
    bpy.context.window.scene = source
    meshes = baked(piece_objects(collections), frame)
    if exclude:
        meshes = [(owner, mesh) for owner, mesh in meshes if not re.search(exclude, owner)]
    if only:
        meshes = [(owner, mesh) for owner, mesh in meshes if re.search(only, owner)]
    scene = bpy.data.scenes.new("export_" + piece)
    stage = bpy.data.collections.new("export_" + piece)
    scene.collection.children.link(stage)
    shell = [mesh for owner, mesh in meshes if not DETAIL.search(owner)]
    detail = [mesh for owner, mesh in meshes if DETAIL.search(owner)]
    hull = [mesh.copy() for owner, mesh in meshes if collide and re.search(collide, owner)]
    parts = [joined("Shell", shell, stage), joined("Detail", detail, stage), joined("Collision-colonly", hull, stage)]
    window = bpy.context.window
    window.scene = scene
    for obj in scene.objects:
        obj.select_set(obj in parts)
    path = TARGET / ("truck_elevator_%s.glb" % piece)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True, export_yup=True,
        export_apply=False, export_materials="EXPORT", export_image_format="NONE", export_normals=True,
        export_texcoords=True, export_attributes=False, export_cameras=False, export_lights=False,
        export_extras=False)
    path.with_suffix(".txt").write_text(CREDIT, encoding="utf-8")
    for obj in parts:
        if obj is not None:
            lo = [min((obj.matrix_world @ Vector(c))[k] for c in obj.bound_box) for k in range(3)]
            hi = [max((obj.matrix_world @ Vector(c))[k] for c in obj.bound_box) for k in range(3)]
            # Godot frame: (x, z, -y) of Blender's after the half turn.
            print("[truck_elevator] %s/%s: %d triangles, godot x %.2f..%.2f y %.2f..%.2f z %.2f..%.2f" % (
                piece, obj.name, sum(len(p.vertices) - 2 for p in obj.data.polygons),
                lo[0], hi[0], lo[2], hi[2], -hi[1], -lo[1]))
    # Free the names for the next piece ("Shell", "Detail"...).
    for obj in [o for o in parts if o is not None]:
        mesh = obj.data
        bpy.data.objects.remove(obj)
        bpy.data.meshes.remove(mesh)
    bpy.data.scenes.remove(scene)


def report_screens() -> None:
    """Where the call kiosks' screens are, in each piece's Godot frame (the scenes put a touch screen there)."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for name, piece in (("screen.001", "top"), ("screen.002", "platform"), ("screen.003", "pit")):
        obj = bpy.data.objects.get(name)
        if obj is None:
            continue
        origin_z = PIECES[piece][1]
        frame = HALF_TURN @ Matrix.Translation(Vector((0.0, -RAIL_FACE_Y, -origin_z)))
        mesh = obj.evaluated_get(depsgraph).to_mesh()
        points = [frame @ obj.matrix_world @ v.co for v in mesh.vertices]
        centre = sum(points, Vector()) / len(points)
        normal = (frame.to_3x3() @ obj.matrix_world.to_3x3() @ mesh.polygons[0].normal).normalized()
        print("[truck_elevator] %s (%s): centre godot (%.3f, %.3f, %.3f), normal (%.3f, %.3f, %.3f), size %s" % (
            name, piece, centre.x, centre.z, -centre.y, normal.x, normal.z, -normal.y,
            tuple(round(d, 3) for d in obj.dimensions)))


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    source = bpy.context.window.scene
    report_screens()
    for piece, spec in PIECES.items():
        export_piece(source, piece, *spec)
    print("[truck_elevator] done")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as error:
        print("[truck_elevator] FAILED:", error)
        sys.exit(1)
