"""Build StarGrotte's original stylized rock pilot in a separate Blender process.

Run with Blender --background --factory-startup --python <this file>.
Metres, Z up in Blender; glTF converts to Godot's Y up. No external assets.
The .blend remains editable. Rebuilding intentionally replaces this pilot only.
"""
from pathlib import Path
import json
import math
import random

import bpy
import bmesh
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assets_blender/stargrot"
TARGET = ROOT / "scenes/planet/cave/assets/rock_stylized"
PREVIEW = ROOT.parent / "stargrot-roches-stylisees.png"
SOURCE.mkdir(parents=True, exist_ok=True)
TARGET.mkdir(parents=True, exist_ok=True)
(SOURCE / ".gdignore").write_text("", encoding="utf-8")

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"
scene.unit_settings.scale_length = 1.0
assets = bpy.data.collections.new("01_ASSETS_METRES")
scene.collection.children.link(assets)
stage = bpy.data.collections.new("02_PRESENTATION_NON_EXPORT")
scene.collection.children.link(stage)


def move_to(obj, collection):
    for owner in list(obj.users_collection):
        owner.objects.unlink(obj)
    collection.objects.link(obj)


material = bpy.data.materials.new("SG_Rock_Sculpted_VertexTint")
material.use_nodes = True
nodes = material.node_tree.nodes
bsdf = nodes.get("Principled BSDF")
bsdf.inputs["Roughness"].default_value = 0.83
bsdf.inputs["Specular IOR Level"].default_value = 0.25
tint = nodes.new("ShaderNodeVertexColor")
tint.layer_name = "RockTint"
material.node_tree.links.new(tint.outputs["Color"], bsdf.inputs["Base Color"])


def sculpt(seed, dimensions, mode="block", detail=3):
    """Low frequency asymmetry, broad fracture planes, rounded chipped edges."""
    rng = random.Random(seed)
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=detail, radius=1.0)
    phase = rng.uniform(0, math.tau)
    for vert in bm.verts:
        p = vert.co.copy()
        wobble = 1 + 0.10 * math.sin(p.x * 4 + phase) * math.cos(p.y * 3 - phase)
        p *= wobble
        p.x += 0.11 * p.z + 0.07 * math.sin(p.y * 4 + phase)
        p.y += 0.12 * p.z * p.z - 0.06 * p.x
        # Unequal planar fractures give a geological silhouette, rather than a noisy sphere.
        for normal, distance in [(Vector((0.7, 0.3, 0.6)).normalized(), 0.68),
                                 (Vector((-0.5, 0.7, 0.2)).normalized(), 0.72),
                                 (Vector((0.15, -0.5, 0.85)).normalized(), 0.75),
                                 (Vector((-.8, -.45, -.1)).normalized(), .8)]:
            excess = p.dot(normal) - distance
            if excess > 0:
                p -= normal * excess
        p.z = max(-0.63, min(p.z, 0.8 if mode == "slab" else 1.1))
        vert.co = p
    points = [v.co.copy() for v in bm.verts]
    bm.free()
    hull = bmesh.new()
    for point in points:
        hull.verts.new(point)
    result = bmesh.ops.convex_hull(hull, input=list(hull.verts))
    bmesh.ops.delete(hull, geom=result["geom_interior"], context="VERTS")
    bmesh.ops.dissolve_limit(hull, angle_limit=0.06, verts=list(hull.verts), edges=list(hull.edges))
    mesh = bpy.data.meshes.new("SculptedStone")
    hull.to_mesh(mesh)
    hull.free()
    fit_mesh(mesh, dimensions)
    return mesh


def fit_mesh(mesh, dimensions):
    low = Vector(tuple(min(v.co[i] for v in mesh.vertices) for i in range(3)))
    high = Vector(tuple(max(v.co[i] for v in mesh.vertices) for i in range(3)))
    center = (low + high) * 0.5
    for v in mesh.vertices:
        v.co = Vector(((v.co.x - center.x) * dimensions[0] / (high.x - low.x),
                       (v.co.y - center.y) * dimensions[1] / (high.y - low.y),
                       (v.co.z - low.z) * dimensions[2] / (high.z - low.z)))


def formation(seed, height, radius, hanging=False):
    rng = random.Random(seed)
    n = 11
    rings = [(0.0, 1.0), (0.09, 0.91), (0.27, 0.65), (0.52, 0.42), (0.76, 0.24),
             (0.93, 0.12), (1.0, 0.025)]
    vertices = []
    for j, (z, width) in enumerate(rings):
        for i in range(n):
            angle = math.tau * i / n
            # Flowstone ribs follow the growth axis, with a slight lean and unequal tip.
            r = radius * width * (1 + 0.13 * math.sin(i * 2.7 + seed) + rng.uniform(-0.035, 0.035))
            x = math.cos(angle) * r + 0.1 * z * z
            y = math.sin(angle) * r * 0.82 + 0.06 * math.sin(z * 3)
            vertices.append((x, y, z * height))
    faces = [tuple(reversed(range(n)))]
    for j in range(len(rings) - 1):
        for i in range(n):
            a, b = j * n + i, j * n + (i + 1) % n
            faces.append((a, b, b + n, a + n))
    faces.append(tuple((len(rings) - 1) * n + i for i in range(n)))
    mesh = bpy.data.meshes.new("FlowstonePendant" if hanging else "FlowstoneSpire")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    return mesh


def finish(name, mesh, seed, bevel=0.025):
    obj = bpy.data.objects.new(name, mesh)
    assets.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    modifier = obj.modifiers.new("Soft fracture edges", "BEVEL")
    modifier.width = bevel
    modifier.segments = 2
    modifier.affect = "EDGES"
    modifier.angle_limit = 0.35
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    # Floor pivot and a shared palette, baked as vertex colours, not six large textures.
    minimum = min(v.co.z for v in obj.data.vertices)
    for vert in obj.data.vertices:
        vert.co.z -= minimum
    colour = obj.data.color_attributes.new(name="RockTint", type="BYTE_COLOR", domain="CORNER")
    rng = random.Random(seed)
    base = (0.31, 0.285, 0.24) if "stal" not in name else (0.41, 0.345, 0.25)
    for polygon in obj.data.polygons:
        center = sum((obj.data.vertices[i].co for i in polygon.vertices), Vector()) / len(polygon.vertices)
        band = 0.018 * math.sin(center.z * 9 + center.x * 0.4)
        variation = rng.uniform(-0.006, 0.006) + band
        polygon.use_smooth = len(polygon.vertices) <= 4
        for loop in polygon.loop_indices:
            colour.data[loop].color = tuple(max(0, min(1, c + variation)) for c in base) + (1.0,)
    obj.data.materials.clear()
    obj.data.materials.append(material)
    obj["units"] = "metres; support at z=0; local +Z points into asset"
    obj["art_direction"] = "Original stylized rock; broad sculpted planes, restrained detail"
    obj.select_set(False)
    return obj


objects = [
    finish("rock_boulder_01", sculpt(73, (1.8, 1.25, 1.1)), 73),
    finish("rock_boulder_02", sculpt(191, (2.25, 1.3, 0.65), "slab"), 191),
    finish("rock_boulder_03", sculpt(317, (1.15, 1.05, 1.65)), 317),
]
# One rubble mesh, six overlapping stones: visual only (a hull over the whole pile would float).
pieces = []
for i, (x, y, z, scale) in enumerate([(-0.4, -0.12, 0, .55), (.23, -.22, 0, .58),
                                     (.0, .3, .02, .65), (.42, .18, 0, .3),
                                     (-.1, -.37, 0, .25), (-.28, .2, .08, .35)]):
    obj = finish("rubble_piece", sculpt(110 + i, (scale, scale * .78, scale * .65), detail=2), 110 + i, .014)
    obj.location = (x, y, z)
    pieces.append(obj)
for obj in pieces:
    obj.select_set(True)
bpy.context.view_layer.objects.active = pieces[0]
bpy.ops.object.join()
rubble = bpy.context.object
rubble.name = "rock_rubble_01"
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
minimum = min(0, min(p.co.z for p in rubble.data.vertices))
for v in rubble.data.vertices:
    v.co.z -= minimum
rubble.select_set(False)
objects.append(rubble)
objects.append(finish("rock_stalagmite_01", formation(423, 2.6, .52), 423, .018))
# Authored pointing up as required by CaveDecorationRule; runtime flips it for ceiling support.
objects.append(finish("rock_stalactite_01", formation(557, 2.15, .42, True), 557, .016))

manifest = {"schema": 1, "direction": "Original stylized sculpted rock, inspired by readable game environments",
            "units": "metres", "source_up": "Z", "runtime_up": "Y", "seeded": True, "assets": []}
positions = [(-3.1, 1.1, 0), (0, 1.1, 0), (3.1, 1.1, 0), (-3.1, -1.7, 0),
             (0, -1.7, 0), (3.1, -1.7, 0)]
for obj, position in zip(objects, positions):
    bpy.ops.object.select_all(action="DESELECT")
    obj.location = (0, 0, 0)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(filepath=str(TARGET / (obj.name + ".glb")), export_format="GLB",
        use_selection=True, export_apply=True, export_yup=True, export_materials="EXPORT",
        export_normals=True, export_texcoords=False, export_attributes=False)
    mesh = obj.data
    mesh.calc_loop_triangles()
    manifest["assets"].append({"id": obj.name, "triangles": len(mesh.loop_triangles),
        "dimensions_m": [round(d, 4) for d in obj.dimensions], "support": "ceiling" if "stalactite" in obj.name else "floor",
        "collision": "convex" if "boulder" in obj.name else "none"})
    obj.location = position
    obj.asset_mark()
    obj.select_set(False)


def simple_material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    mat.use_nodes = True
    mat.node_tree.nodes.get("Principled BSDF").inputs["Base Color"].default_value = (*color, 1)
    mat.node_tree.nodes.get("Principled BSDF").inputs["Roughness"].default_value = .9
    return mat


floor = simple_material("Presentation_ink", (.025, .045, .055))
letter = simple_material("Presentation_labels", (.56, .77, .72))
for obj in objects:
    bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=1.34, depth=.10,
        location=(obj.location.x, obj.location.y, -.07))
    plinth = bpy.context.object
    move_to(plinth, stage)
    plinth.data.materials.append(floor)
    bpy.ops.object.text_add(location=(obj.location.x - 1.1, obj.location.y - 1.24, .005))
    label = bpy.context.object
    move_to(label, stage)
    label.data.body = obj.name.replace("rock_", "").replace("_01", " / 01").replace("_02", " / 02").replace("_03", " / 03")
    label.data.size = .18
    label.data.extrude = .001
    label.data.materials.append(letter)
bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, -.14))
move_to(bpy.context.object, stage)
bpy.context.object.data.materials.append(floor)


def aim(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


bpy.ops.object.camera_add(location=(7.8, -12.8, 10.0))
camera = bpy.context.object
move_to(camera, stage)
aim(camera, (0, 0, .5))
camera.data.type = "ORTHO"
camera.data.ortho_scale = 12.0
scene.camera = camera
for name, loc, energy, color, size in [
    ("Key_warm", (-3, -4, 8), 1700, (1.0, .83, .65), 6),
    ("Fill_cool", (5, -1, 5), 1100, (.56, .77, 1), 5),
    ("Rim_mint", (-1, 6, 5), 2000, (.66, 1, .85), 4),
]:
    bpy.ops.object.light_add(type="AREA", location=loc)
    light = bpy.context.object
    move_to(light, stage)
    light.name = name
    light.data.energy, light.data.color, light.data.shape, light.data.size = energy, color, "DISK", size
    aim(light, (0, 0, .5))
scene.world.color = (.18, .18, .18)
scene.render.engine = "CYCLES"
scene.cycles.samples = 40
scene.cycles.use_denoising = True
scene.render.resolution_x = 1600
scene.render.resolution_y = 1100
scene.render.resolution_percentage = 100
scene.view_settings.view_transform = "AgX"
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = str(PREVIEW)
scene["README"] = "Collection 01: original game meshes, metres. Collection 02: presentation only. Six GLBs exported at origin. Rebuild script: tools/stargrot/build_rock_assets.py."
bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE / "stargrot_rock_pilot.blend"))
(TARGET / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
bpy.ops.render.render(write_still=True)
print("STARGROT ROCK ASSETS", json.dumps(manifest))
