"""Original exterior geology, independent of the six interior cave meshes.

Blender --background --factory-startup --python tools/stargrot/build_exterior_rocks.py
Metres, Blender Z up. Fractured blocks, slabs, wedges, erratics and layered outcrops.
"""
from pathlib import Path
import json
import math
import random

import bpy
import bmesh
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "scenes/planet/cave/assets/rock_exterior"
SOURCE = ROOT / "assets_blender/stargrot/exterior"
TARGET.mkdir(parents=True, exist_ok=True)
SOURCE.mkdir(parents=True, exist_ok=True)
(SOURCE / ".gdignore").write_text("", encoding="utf-8")
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.context.scene.unit_settings.system = "METRIC"


def fractured(seed, kind, dims):
    rng = random.Random(seed)
    bm = bmesh.new()
    if kind == "erratic":
        bmesh.ops.create_icosphere(bm, subdivisions=3, radius=1)
        for v in bm.verts:
            v.co *= 1 + .1 * math.sin(v.co.x * 3 + seed) * math.cos(v.co.z * 4)
            v.co.x += .17 * v.co.z * v.co.z
    else:
        # Different corner counts, sections and plane directions change the actual silhouettes.
        count = 3 if kind == "wedge" else (5 if kind == "elongated" else 4)
        for level in range(3):
            for i in range(count):
                angle = math.tau * i / count + (.2 if kind == "slab" else .65)
                angle += rng.uniform(-.12, .12) + level * rng.uniform(-.16, .16)
                width = [rng.uniform(.75, 1), 1, rng.uniform(.5, .9)][level]
                x = math.cos(angle) * width + level * rng.uniform(-.18, .18)
                y = math.sin(angle) * width + level * rng.uniform(-.2, .2)
                z = level - 1 + rng.uniform(-.18, .18)
                bm.verts.new((x, y, z))
    hull = bmesh.ops.convex_hull(bm, input=list(bm.verts))
    if hull.get("geom_interior"):
        bmesh.ops.delete(bm, geom=hull["geom_interior"], context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    mesh = bpy.data.meshes.new("ExteriorFracture")
    bm.to_mesh(mesh)
    bm.free()
    low = Vector(tuple(min(v.co[i] for v in mesh.vertices) for i in range(3)))
    high = Vector(tuple(max(v.co[i] for v in mesh.vertices) for i in range(3)))
    for v in mesh.vertices:
        v.co = Vector(((v.co.x - (low.x + high.x) / 2) * dims[0] / (high.x - low.x),
                       (v.co.y - (low.y + high.y) / 2) * dims[1] / (high.y - low.y),
                       (v.co.z - low.z) * dims[2] / (high.z - low.z)))
    return mesh


material = bpy.data.materials.new("ExteriorRockTint")
material.diffuse_color = (.58, .56, .53, 1)
objects = []
manifest = {"schema": 1, "purpose": "Dedicated exterior entrance geology", "assets": []}
families = [("block", (2.5, 1.9, 1.65)), ("slab", (3.7, 2.15, .65)),
            ("wedge", (2.1, 1.3, 2.2)), ("elongated", (3.9, 1.25, 1.25)),
            ("erratic", (2.4, 2.0, 1.8)), ("layered", (3.2, 1.8, 1.9))]
for family_index, (kind, dimensions) in enumerate(families):
    for variant in range(2):
        seed = 7103 + family_index * 127 + variant * 37
        rng = random.Random(seed)
        name = f"exterior_{kind}_{variant + 1:02}"
        dims = tuple(d * rng.uniform(.85, 1.12) for d in dimensions)
        pieces = []
        for layer in range(3 if kind == "layered" else 1):
            part_dims = (dims[0] * (1 - layer * .14), dims[1], dims[2] / 3 * 1.08) if kind == "layered" else dims
            mesh = fractured(seed + layer, "block" if kind == "layered" else kind, part_dims)
            obj = bpy.data.objects.new(name, mesh)
            bpy.context.collection.objects.link(obj)
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
            bevel = obj.modifiers.new("Weathered fracture edges", "BEVEL")
            bevel.width = .035 if kind == "erratic" else .018
            bevel.segments = 2
            bpy.ops.object.modifier_apply(modifier=bevel.name)
            obj.location = (.1 * layer, -.1 * layer, layer * dims[2] / 3 * .88)
            obj.select_set(False)
            pieces.append(obj)
        for obj in pieces:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = pieces[0]
        bpy.ops.object.join()
        obj = bpy.context.object
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        obj.name = name
        low = min(v.co.z for v in obj.data.vertices)
        for v in obj.data.vertices:
            v.co.z -= low
        colors = obj.data.color_attributes.new(name="RockTint", type="BYTE_COLOR", domain="CORNER")
        for polygon in obj.data.polygons:
            shade = rng.uniform(.58, .69)
            polygon.use_smooth = kind == "erratic"
            for loop in polygon.loop_indices:
                colors.data[loop].color = (shade, shade * .98, shade * .94, 1)
        obj.data.materials.append(material)
        bpy.ops.export_scene.gltf(filepath=str(TARGET / (name + ".glb")), export_format="GLB",
            use_selection=True, export_apply=True, export_yup=True, export_materials="EXPORT", export_normals=True)
        obj.data.calc_loop_triangles()
        manifest["assets"].append({"id": name, "family": kind, "triangles": len(obj.data.loop_triangles),
            "dimensions_m": list(obj.dimensions), "seed": seed})
        obj.asset_mark()
        obj.location = (family_index * 5.0, variant * 4.5, 0)
        obj.select_set(False)
        objects.append(obj)
credit = "Procedural - StarGrotte (Codex) - https://github.com/DyingStar-game/DyingStar - CC BY-NC-SA 4.0\n"
for obj in objects:
    (TARGET / (obj.name + ".txt")).write_text(credit, encoding="utf-8")
(SOURCE / "exterior_rocks.txt").write_text(credit, encoding="utf-8")
(TARGET / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE / "exterior_rocks.blend"))
print("STARGROT EXTERIOR ART", len(objects), "new meshes")
