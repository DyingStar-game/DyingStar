"""Corundum ground rocks for Nova's scatter: stratified outcrops, slabs, boulders and rubble.

    blender --background --factory-startup --python tools/nova/build_corundum_rocks.py -- [--export] [--render]

Geometry only, on purpose. The rocks wear the ground's own material in the game (the biome's textures laid
by world position, tinted with the rock's colour from rocks.json), so one set serves every corundum, a rock
never clashes with the ground it stands on, and no texture is baked or shipped per model. What a model
carries besides its triangles is one vertex colour: the light its own shape lets in (ambient occlusion),
which is what makes strata and crevices read at any hour.

Metres, Blender Z up. A model's origin is at ground level; it reaches below it (SINK) so it never floats on a
slope, and its underside is left open: nothing looks at a rock from below.

Writes the editable source and a manifest to assets_blender/nova/corundum/ (ignored by Godot); with --export
also one GLB per model to scenes/planet/nova/assets/rock_corundum/; with --render two preview pictures.
"""
from pathlib import Path
import json
import math
import random
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assets_blender/nova/corundum"
TARGET = ROOT / "scenes/planet/nova/assets/rock_corundum"
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

# Share of a model's footprint radius it reaches below the ground: clear of a ~20 degree slope.
SINK = 0.36
# Ambient occlusion: rays per corner, their reach (m), and the darkest a corner gets.
AO_RAYS = 24
AO_REACH = 2.5
AO_FLOOR = 0.5

# name: (kind, seed, footprint radius m, height m). Budgets in triangles are checked at the end.
MODELS = {
    "corundum_outcrop_01": ("outcrop", 11, 6.5, 3.4),
    "corundum_outcrop_02": ("outcrop", 12, 5.0, 2.4),
    "corundum_outcrop_03": ("outcrop", 13, 8.0, 4.4),
    "corundum_slab_01": ("slab", 21, 2.4, 0.8),
    "corundum_slab_02": ("slab", 22, 1.8, 0.6),
    "corundum_slab_03": ("slab", 23, 3.0, 1.0),
    "corundum_boulder_01": ("boulder", 31, 0.8, 1.0),
    "corundum_boulder_02": ("boulder", 32, 0.6, 0.7),
    "corundum_boulder_03": ("boulder", 33, 1.1, 1.3),
    "corundum_rubble_01": ("rubble", 41, 1.4, 0.35),
    "corundum_rubble_02": ("rubble", 42, 1.1, 0.3),
}
BUDGET = {"outcrop": 1100, "slab": 220, "boulder": 160, "rubble": 420}


def outline(rng, count, radius, squash, rough):
    """A closed, irregular outline around the origin: [(x, y)], counter-clockwise."""
    turn = rng.uniform(0.0, math.tau)
    points = []
    for i in range(count):
        angle = math.tau * (i + rng.uniform(-0.3, 0.3)) / count
        r = radius * (1.0 + rng.uniform(-rough, rough))
        x, y = math.cos(angle) * r, math.sin(angle) * r * squash
        points.append((x * math.cos(turn) - y * math.sin(turn), x * math.sin(turn) + y * math.cos(turn)))
    return points


def split(polygon, point, normal):
    """Cut a convex polygon by the line through [point] with [normal]: the piece on each side (either may
    be missing)."""
    sides = [[], []]
    n = len(polygon)
    for i in range(n):
        a, b = polygon[i], polygon[(i + 1) % n]
        da = (a[0] - point[0]) * normal[0] + (a[1] - point[1]) * normal[1]
        db = (b[0] - point[0]) * normal[0] + (b[1] - point[1]) * normal[1]
        sides[0 if da >= 0.0 else 1].append(a)
        if (da >= 0.0) != (db >= 0.0):
            t = da / (da - db)
            cut = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            sides[0].append(cut)
            sides[1].append(cut)
    return [side for side in sides if len(side) >= 3]


def area(polygon):
    n = len(polygon)
    return 0.5 * abs(sum(polygon[i][0] * polygon[(i + 1) % n][1] - polygon[(i + 1) % n][0] * polygon[i][1]
            for i in range(n)))


def block(bm, polygon, low, high, rng, gap):
    """One block of a bed: the polygon drawn in by [gap] (the open joint around it), its sides and its top,
    the top a little out of level. No underside: it rests on the bed below or in the ground."""
    cx = sum(p[0] for p in polygon) / len(polygon)
    cy = sum(p[1] for p in polygon) / len(polygon)
    reach = max(math.hypot(p[0] - cx, p[1] - cy) for p in polygon)
    keep = max(1.0 - gap / max(reach, 0.01), 0.6)
    lean = (rng.uniform(-0.06, 0.06), rng.uniform(-0.06, 0.06))
    foot, top = [], []
    for x, y in polygon:
        x, y = cx + (x - cx) * keep, cy + (y - cy) * keep
        foot.append(bm.verts.new((x, y, low)))
        worn = rng.uniform(0.93, 1.0)
        top.append(bm.verts.new((cx + (x - cx) * worn, cy + (y - cy) * worn,
                high + (x - cx) * lean[0] + (y - cy) * lean[1])))
    n = len(polygon)
    for i in range(n):
        bm.faces.new((foot[i], foot[(i + 1) % n], top[(i + 1) % n], top[i]))
    bm.faces.new(top)
    return foot + top


def beds(bm, rng, radius, height, squash, count, joints, dip_side):
    """A stack of jointed beds, as a ledge of layered rock breaks: every bed is cut into blocks by a few
    fractures; it steps back a little on the scarp and a lot down the dip ([dip_side], a unit vector); here
    and there a block is gone."""
    shape = outline(rng, 9, radius, squash, 0.14)
    # Every block stands on the ground, through the beds under it: the stack is one solid mass with open
    # joints, never planks with daylight between them. Deep enough to stay buried once the beds are dipped.
    foot = -radius * 0.6
    level = 0.0
    for bed in range(count):
        thickness = height / count * rng.uniform(0.6, 1.5)
        pieces = [shape]
        for _ in range(joints):
            point = (rng.uniform(-0.45, 0.45) * radius, rng.uniform(-0.45, 0.45) * radius * squash)
            angle = rng.uniform(0.0, math.pi)
            normal = (math.cos(angle), math.sin(angle))
            pieces = [part for piece in pieces for part in split(piece, point, normal)]
        whole = area(shape)
        for piece in pieces:
            if area(piece) < whole * 0.02:
                continue  # a sliver: crumbled away
            if bed > 0 and rng.random() < 0.16:
                continue  # gone: a notch in the ledge
            block(bm, piece, foot, level + thickness * rng.uniform(0.85, 1.0), rng, rng.uniform(0.02, 0.07))
        level += thickness
        # The next bed: drawn in, and slid towards the dip side so the other side stays a scarp.
        scale = rng.uniform(0.8, 0.94)
        slide = radius * rng.uniform(0.05, 0.16)
        shape = [(x * scale - dip_side[0] * slide, y * scale - dip_side[1] * slide) for x, y in shape]
    return level


def boulder(bm, rng, radius, height, squash, points, cuts):
    """A broken block: the hull of points scattered in an ellipsoid, then struck off along a few planes —
    the large flat faces a fracture leaves, among the small ones."""
    verts = []
    for _ in range(points):
        d = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))).normalized() * rng.uniform(0.7, 1.0)
        verts.append(bm.verts.new((d.x * radius, d.y * radius * squash, (d.z * 0.5 + 0.5) * height)))
    result = bmesh.ops.convex_hull(bm, input=verts)
    inside = [g for g in result.get("geom_interior", []) if isinstance(g, bmesh.types.BMVert)]
    if inside:
        bmesh.ops.delete(bm, geom=inside, context="VERTS")
    made = {v for v in verts if v.is_valid}
    for _ in range(cuts):
        normal = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.uniform(0.1, 1.0))).normalized()
        at = Vector((0, 0, height * 0.5)) + Vector((normal.x * radius, normal.y * radius * squash,
                normal.z * height * 0.5)) * rng.uniform(0.45, 0.75)
        geom = list(made) + [e for e in bm.edges if e.verts[0] in made and e.verts[1] in made] \
                + [f for f in bm.faces if all(v in made for v in f.verts)]
        cut = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=at, plane_no=normal, clear_outer=True)
        rim = [e for e in cut["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
        made = {v for v in made if v.is_valid} | {v for e in rim for v in e.verts}
        if rim:
            filled = bmesh.ops.holes_fill(bm, edges=rim, sides=0)
            made |= {v for f in filled.get("faces", []) for v in f.verts}
    return [v for v in made if v.is_valid]


def tilt(bm, verts, rng, degrees, towards):
    """Dip the beds towards unit direction [towards]: real strata never lie level."""
    turn = Matrix.Rotation(math.atan2(towards[1], towards[0]) + math.pi / 2, 4, "Z")
    dip = Matrix.Rotation(math.radians(rng.uniform(*degrees)), 4, "X")
    bmesh.ops.transform(bm, matrix=turn @ dip @ turn.inverted(), verts=verts)


def build(kind, seed, radius, height):
    rng = random.Random(seed)
    bm = bmesh.new()
    angle = rng.uniform(0, math.tau)
    dip_side = (math.cos(angle), math.sin(angle))
    if kind == "outcrop":
        # The main ledge, then lesser ones beside it broken off the same beds: same dip, other heights.
        beds(bm, rng, radius, height, rng.uniform(0.6, 0.8), rng.randint(5, 6), 3, dip_side)
        for _ in range(2):
            before = set(bm.verts)
            beds(bm, rng, radius * rng.uniform(0.35, 0.5), height * rng.uniform(0.35, 0.6),
                    rng.uniform(0.55, 0.9), rng.randint(2, 3), 2, dip_side)
            added = [v for v in bm.verts if v not in before]
            side = rng.uniform(0, math.tau)
            bmesh.ops.translate(bm, verts=added,
                    vec=Vector((math.cos(side), math.sin(side), 0.0)) * radius * rng.uniform(0.7, 0.95))
        tilt(bm, list(bm.verts), rng, (7, 15), dip_side)
    elif kind == "slab":
        beds(bm, rng, radius, height, rng.uniform(0.5, 0.75), 2, 2, dip_side)
        tilt(bm, list(bm.verts), rng, (12, 28), dip_side)
    elif kind == "boulder":
        boulder(bm, rng, radius, height, rng.uniform(0.7, 1.0), 34, 3)
    else:  # rubble: a handful of small blocks, one model so a patch costs one draw
        for _ in range(rng.randint(9, 12)):
            stones = boulder(bm, rng, rng.uniform(0.09, 0.26), rng.uniform(0.12, height), rng.uniform(0.6, 1.0), 10, 1)
            turn, away = rng.uniform(0, math.tau), radius * math.sqrt(rng.random())
            bmesh.ops.rotate(bm, verts=stones, cent=(0, 0, 0), matrix=Matrix.Rotation(rng.uniform(0, math.tau), 3, "Z"))
            bmesh.ops.translate(bm, verts=stones, vec=(math.cos(turn) * away, math.sin(turn) * away, 0.0))
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    # Down into the ground, then cut off what lies deeper than a slope can uncover.
    sink = SINK * radius if kind != "rubble" else 0.08
    # Beds already stand on deep feet (their ground level is z = 0); a block or rubble rests on its lowest point.
    low = 0.0 if kind in ("outcrop", "slab") else min(v.co.z for v in bm.verts)
    bmesh.ops.translate(bm, verts=list(bm.verts), vec=(0, 0, -low - sink * 0.35))
    bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
            plane_co=(0, 0, -sink), plane_no=(0, 0, 1), clear_inner=True)
    bmesh.ops.triangulate(bm, faces=list(bm.faces))
    mesh = bpy.data.meshes.new(kind)
    bm.to_mesh(mesh)
    bm.free()
    for polygon in mesh.polygons:
        polygon.use_smooth = False  # broken rock: every face its own facet
    return mesh


def occlusion(mesh):
    """Bake how much sky each corner sees into the "Col" colour: rays over the hemisphere of its face,
    against the model itself and the ground it stands in."""
    tree = BVHTree.FromPolygons([v.co for v in mesh.vertices], [p.vertices for p in mesh.polygons])
    rng = random.Random(7)
    rays = []
    while len(rays) < AO_RAYS:
        d = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))).normalized()
        if d.z > -0.2:
            rays.append(d)
    colours = mesh.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    for polygon in mesh.polygons:
        for loop in polygon.loop_indices:
            at = mesh.vertices[mesh.loops[loop].vertex_index].co
            # A little towards the face's middle and off it: a corner on an edge would hit its own neighbours.
            start = at.lerp(polygon.center, 0.15) + polygon.normal * 0.03
            seen = total = 0.0
            for d in rays:
                weight = d.dot(polygon.normal)
                if weight <= 0.05:
                    continue
                total += weight
                blocked = tree.ray_cast(start, d, AO_REACH)[0] is not None
                # The ground: a ray heading down from near it is stopped by it.
                if not blocked and d.z < 0.0 and start.z + d.z * AO_REACH < 0.0:
                    blocked = True
                seen += 0.0 if blocked else weight
            light = seen / total if total > 0.0 else 1.0
            # In the ground itself it is dark: the foot of the rock sits in its own shade.
            light *= min(max((at.z + 0.05) / 0.35, 0.0), 1.0) * 0.5 + 0.5
            value = AO_FLOOR + (1.0 - AO_FLOOR) * light
            colours.data[loop].color = (value, value, value, 1.0)


def plain_material(name, colour, baked_light):
    """For the pictures only (the game gives the rocks the ground's material)."""
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    shader = nodes["Principled BSDF"]
    shader.inputs["Roughness"].default_value = 0.9
    shader.inputs["Base Color"].default_value = colour
    if baked_light:
        light = nodes.new("ShaderNodeVertexColor")
        light.layer_name = "Col"
        mix = nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MULTIPLY"
        mix.inputs[0].default_value = 1.0
        mix.inputs[6].default_value = colour
        links.new(light.outputs["Color"], mix.inputs[7])
        links.new(mix.outputs[2], shader.inputs["Base Color"])
    return material


def render(path, shown, eye, target, lens):
    scene = bpy.context.scene
    for obj in bpy.data.objects:
        if obj.type == "MESH":
            obj.hide_render = obj not in shown and obj.name != "PreviewGround"
    camera = bpy.data.objects.get("PreviewCamera")
    if camera is None:
        camera = bpy.data.objects.new("PreviewCamera", bpy.data.cameras.new("PreviewCamera"))
        scene.collection.objects.link(camera)
        sun = bpy.data.objects.new("PreviewSun", bpy.data.lights.new("PreviewSun", "SUN"))
        sun.data.energy = 4.5
        sun.data.angle = math.radians(2.0)
        sun.rotation_euler = (math.radians(58), 0.0, math.radians(40))
        scene.collection.objects.link(sun)
        scene.world = bpy.data.worlds.new("PreviewSky")
        scene.world.use_nodes = True
        scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.6, 0.7, 1.0)
        scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
    camera.location = eye
    camera.rotation_euler = (Vector(target) - Vector(eye)).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = lens
    scene.camera = camera
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 48
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = 1600, 900
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def main():
    SOURCE.mkdir(parents=True, exist_ok=True)
    (SOURCE / ".gdignore").write_text("", encoding="utf-8")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.context.scene.unit_settings.system = "METRIC"
    rock = plain_material("CorundumPreview", (0.42, 0.11, 0.08, 1.0), True)
    manifest = {}
    objects = {}
    back = front = 0.0
    for name, (kind, seed, radius, height) in MODELS.items():
        mesh = build(kind, seed, radius, height)
        mesh.name = name
        occlusion(mesh)
        mesh.materials.append(rock)
        obj = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        # Two rows in the source file: the outcrops behind, the rest in front.
        if kind == "outcrop":
            back += radius + 2.0
            obj.location = (back, 16.0, 0.0)
            back += radius + 2.0
        else:
            front += radius + 0.9
            obj.location = (front * 1.5, 0.0, 0.0)
            front += radius + 0.9
        objects[name] = obj
        low = [min(v.co[i] for v in mesh.vertices) for i in range(3)]
        high = [max(v.co[i] for v in mesh.vertices) for i in range(3)]
        triangles = len(mesh.polygons)
        assert triangles <= BUDGET[kind], "%s: %d triangles, budget %d" % (name, triangles, BUDGET[kind])
        manifest[name] = {"kind": kind, "seed": seed, "triangles": triangles,
                "size_m": [round(high[i] - low[i], 2) for i in range(3)],
                "above_ground_m": round(high[2], 2), "below_ground_m": round(-low[2], 2)}
        print("%-22s %4d triangles  %5.1f x %5.1f x %4.1f m  (%.1f m above ground)" % (
                name, triangles, high[0] - low[0], high[1] - low[1], high[2] - low[2], high[2]))
    (SOURCE / "manifest.json").write_text(json.dumps(manifest, indent="\t") + "\n", encoding="utf-8")
    print("total: %d models, %d triangles" % (len(manifest), sum(m["triangles"] for m in manifest.values())))

    if "--export" in ARGS:
        TARGET.mkdir(parents=True, exist_ok=True)
        for name, obj in objects.items():
            bpy.ops.object.select_all(action="DESELECT")
            obj.select_set(True)
            where = obj.location.copy()
            obj.location = (0, 0, 0)
            bpy.ops.export_scene.gltf(filepath=str(TARGET / (name + ".glb")), use_selection=True,
                    export_format="GLB", export_materials="NONE", export_apply=True, export_yup=True,
                    export_vertex_color="ACTIVE", export_all_vertex_colors=True)
            obj.location = where
        print("exported to %s" % TARGET)

    if "--render" in ARGS:
        ground = bpy.data.objects.new("PreviewGround", bpy.data.meshes.new("PreviewGround"))
        bm = bmesh.new()
        bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=400.0)
        bm.to_mesh(ground.data)
        bm.free()
        ground.data.materials.append(plain_material("PreviewSoil", (0.3, 0.085, 0.065, 1.0), False))
        bpy.context.scene.collection.objects.link(ground)
        middle = max(back, front * 1.5) * 0.5
        render(SOURCE / "preview_models.png", list(objects.values()), (middle, -24.0, 13.0), (middle, 7.0, 0.5), 30)
        # A field as the scatter would lay it: instances in clumps, open ground between them.
        rng = random.Random(3)
        field = []
        counts = {"outcrop": 5, "slab": 14, "boulder": 40, "rubble": 60}
        clumps = [(rng.uniform(-24, 24), rng.uniform(2, 55)) for _ in range(5)]
        for kind, count in counts.items():
            names = [n for n, m in MODELS.items() if m[0] == kind]
            for _ in range(count):
                cx, cy = rng.choice(clumps)
                spread = 13.0 if kind == "outcrop" else 9.0
                copy = bpy.data.objects.new("Field", objects[rng.choice(names)].data)
                copy.location = (cx + rng.gauss(0, spread), cy + rng.gauss(0, spread), 0.0)
                copy.rotation_euler = (0.0, 0.0, rng.uniform(0, math.tau))
                copy.scale = (rng.uniform(0.7, 1.3),) * 3
                bpy.context.scene.collection.objects.link(copy)
                field.append(copy)
        render(SOURCE / "preview_field.png", field, (0.0, -16.0, 1.9), (0.0, 30.0, 1.0), 22)
        for copy in field:
            bpy.data.objects.remove(copy)
        bpy.data.objects.remove(ground)

    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE / "corundum_rocks.blend"))


main()
