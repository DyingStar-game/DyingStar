"""Game-ready scanned rocks (Poly Haven, CC0) for Nova's red-corundum plateau.

    blender --background --factory-startup --python tools/nova/build_scanned_rocks.py -- [--qa DIR]

Reads the glTF 1k packages downloaded from Poly Haven into assets_blender/nova/scanned/downloads/<asset_id>/
(one folder per asset, files exactly as served by dl.polyhaven.org) and writes, per asset, into
assets_blender/nova/scanned/export/:

  <asset_id>.glb  one mesh, one material, metres, glTF +Y up. Origin at ground level under the model's centre,
                  the model sunk SINK of its height below it so it never floats on a slope. Decimated (collapse,
                  UVs kept) to the budget of its category, smooth normals: the scan's normal map carries the
                  detail. Three 1024 px textures embedded: base colour turned grey and stretched to a light
                  mid-grey (the game multiplies the biome's rock colour into it), the OpenGL normal map as glTF
                  expects, and an ORM map (R occlusion, G roughness floored at ROUGH_FLOOR, B metallic = 0).

plus manifest.json, SOURCES.txt (credits) and preview.png (Cycles, every model in a row, tinted red-brown the way
the game would). The working textures go to assets_blender/nova/scanned/textures/ and the scene is saved as
assets_blender/nova/scanned/scanned_rocks.blend. The whole scanned/ folder carries a .gdignore.

--qa DIR also renders two close-ups per model (three-quarter and top) into DIR, for checking holes and seams.

Downloaded files are only ever read as data (glTF geometry, JPEG images).
"""
from pathlib import Path
import json
import math
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "assets_blender/nova/scanned"
DOWNLOADS = BASE / "downloads"
EXPORT = BASE / "export"
TEXTURES = BASE / "textures"
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
QA_DIR = Path(ARGS[ARGS.index("--qa") + 1]) if "--qa" in ARGS else None

SINK = 0.08            # share of the model's height that goes below y = 0
TEX = 1024             # texture size, px
GREY_MEAN = 0.45       # target linear mean of the grey base colour
GREY_RANGE = (0.10, 0.85)  # linear values the 1st / 99th luminance percentiles map to (before the mean fit)
ROUGH_FLOOR = 0.55     # dry desert rock: no wet-looking glossy patches (rock_07 has some in its scan)
TINT = (0.72, 0.29, 0.22)  # preview only: the biome rock colour multiplied into the base colour
BUDGET = {"small": 800, "medium": 2000, "large": 4500}
LICENCE = "CC0 1.0 (Poly Haven, https://polyhaven.com/license)"

# asset id: (category, display name, authors as given by api.polyhaven.com/info/<id>)
ASSETS = {
    "namaqualand_boulder_03": ("large", "Namaqualand Boulder 03", "Jenelle van Heerden, Dario Barresi"),
    "namaqualand_boulder_04": ("large", "Namaqualand Boulder 04", "Jenelle van Heerden"),
    "namaqualand_boulder_02": ("medium", "Namaqualand Boulder 02", "Greg Zaal, Rico Cilliers"),
    "boulder_01": ("medium", "Boulder 01", "Rico Cilliers"),
    "namaqualand_boulder_05": ("medium", "Namaqualand Boulder 05", "Jenelle van Heerden, Dario Barresi"),
    "namaqualand_boulder_06": ("medium", "Namaqualand Boulder 06", "Greg Zaal, Jenelle van Heerden"),
    "namaqualand_boulders_01": ("small", "Namaqualand Boulders 01", "Greg Zaal, Jenelle van Heerden"),
    "moon_rock_02": ("small", "Moon Rock 02", "Rico Cilliers, Greg Zaal, Jenelle van Heerden"),
    "rock_07": ("small", "Rock 07", "Jenelle van Heerden"),
}
# Downloaded, looked at, left out (id: reason). Kept here so a rebuild does not bring them back.
DROPPED = {
    "namaqualand_cliff_01": "open drone-scan shell: only the front face exists, the back and sides show the "
                            "hollow inside (577 open edges up to the top) - a hole from behind in a field",
    "namaqualand_cliff_02": "open drone-scan shell, same as cliff 01 (1030 open edges up to the top), and tilted: "
                            "one end lifts off the ground",
}


# ---------------------------------------------------------------- images

def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def load_rgba(path):
    """Pixels of an image file as stored (no colour transform), float32 (TEX, TEX, 4)."""
    img = bpy.data.images.load(str(path), check_existing=False)
    img.colorspace_settings.name = "Non-Color"
    if tuple(img.size) != (TEX, TEX):
        img.scale(TEX, TEX)
    buf = np.empty(TEX * TEX * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    bpy.data.images.remove(img)
    return buf.reshape(TEX, TEX, 4)


def save_image(name, rgba, colorspace):
    """Writes rgba (stored values) to textures/<name>.jpg and returns the Blender image reading it."""
    TEXTURES.mkdir(parents=True, exist_ok=True)
    path = TEXTURES / f"{name}.jpg"
    old = bpy.data.images.get(name)
    if old:
        bpy.data.images.remove(old)
    img = bpy.data.images.new(name, TEX, TEX, alpha=False)
    img.colorspace_settings.name = colorspace
    px = rgba.copy()
    px[..., 3] = 1.0
    img.pixels.foreach_set(px.ravel())
    img.filepath_raw = str(path)
    img.file_format = "JPEG"
    img.save(quality=92)
    bpy.data.images.remove(img)
    img = bpy.data.images.load(str(path), check_existing=False)
    img.name = name
    img.colorspace_settings.name = colorspace
    return img


def grey_base_colour(diff):
    """Luminance in linear space, percentile-stretched, curved so its mean is GREY_MEAN, back to sRGB."""
    lin = srgb_to_linear(diff[..., :3])
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    lo, hi = np.percentile(lum, [1.0, 99.0])
    n = np.clip((lum - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    a, b = GREY_RANGE
    g_lo, g_hi = 0.05, 20.0  # exponent bisection: mean(a + (b - a) * n**g) decreases with g
    for _ in range(40):
        g = math.sqrt(g_lo * g_hi)
        if (a + (b - a) * np.power(n, g)).mean() > GREY_MEAN:
            g_lo = g
        else:
            g_hi = g
    out = a + (b - a) * np.power(n, g)
    s = linear_to_srgb(out).astype(np.float32)
    rgba = np.empty_like(diff)
    rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = s
    rgba[..., 3] = 1.0
    return rgba, float(out.mean())


def gltf_output_group():
    """The node group the glTF exporter reads ambient occlusion from."""
    ng = bpy.data.node_groups.get("glTF Material Output")
    if ng is None:
        ng = bpy.data.node_groups.new("glTF Material Output", "ShaderNodeTree")
        ng.interface.new_socket("Occlusion", in_out="INPUT", socket_type="NodeSocketFloat")
    return ng


def build_material(name, base_img, nor_img, orm_img):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    out.location = (600, 0)
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (300, 0)
    links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    base = nodes.new("ShaderNodeTexImage")
    base.name = base.label = "base_colour"
    base.image = base_img
    base.location = (-500, 300)
    links.new(base.outputs["Color"], bsdf.inputs["Base Color"])

    orm = nodes.new("ShaderNodeTexImage")
    orm.name = orm.label = "orm"
    orm.image = orm_img
    orm.location = (-500, 0)
    sep = nodes.new("ShaderNodeSeparateColor")
    sep.location = (-200, 0)
    links.new(orm.outputs["Color"], sep.inputs["Color"])
    links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    occ = nodes.new("ShaderNodeGroup")
    occ.node_tree = gltf_output_group()
    occ.location = (300, -400)
    links.new(sep.outputs["Red"], occ.inputs["Occlusion"])

    nor = nodes.new("ShaderNodeTexImage")
    nor.name = nor.label = "normal"
    nor.image = nor_img
    nor.location = (-500, -300)
    nmap = nodes.new("ShaderNodeNormalMap")
    nmap.location = (-200, -300)
    links.new(nor.outputs["Color"], nmap.inputs["Color"])
    links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


# ---------------------------------------------------------------- geometry

def select_only(objs, active):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active


def triangles(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def import_asset(asset_id):
    folder = DOWNLOADS / asset_id
    gltf = folder / f"{asset_id}_1k.gltf"
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(gltf), merge_vertices=True, import_shading="SMOOTH")
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == "MESH"]
    others = [o.name for o in new if o.type != "MESH"]
    select_only(meshes, meshes[0])
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    for name in others:
        if name in bpy.data.objects:
            bpy.data.objects.remove(bpy.data.objects[name])
    obj.parent = None
    select_only([obj], obj)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.name = obj.data.name = asset_id
    me = obj.data
    # glTF splits vertices along UV seams; weld them back so the decimator sees one closed surface
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    # close what the scan left open (only the underside of boulder 02); a cap corner borrows the UV the
    # same vertex already has on the scanned surface, so the cap wears the neighbouring rock colour
    old_faces = set(bm.faces)
    bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary], sides=0)
    uv = bm.loops.layers.uv.active
    if uv is not None:
        for f in bm.faces:
            if f in old_faces:
                continue
            for loop in f.loops:
                donor = next((l for l in loop.vert.link_loops if l.face in old_faces), None)
                if donor is not None:
                    loop[uv].uv = donor[uv].uv
    bm.to_mesh(me)
    bm.free()
    for attr in list(me.color_attributes):
        me.color_attributes.remove(attr)
    while len(me.uv_layers) > 1:
        me.uv_layers.remove(me.uv_layers[-1])
    bpy.ops.mesh.customdata_custom_splitnormals_clear()
    for slot_mat in list(me.materials):
        if slot_mat is not None:
            bpy.data.materials.remove(slot_mat)
    me.materials.clear()
    return obj


def decimate(obj, budget):
    source = triangles(obj)
    for _ in range(6):
        tris = triangles(obj)
        if tris <= budget:
            break
        mod = obj.modifiers.new("decimate", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = budget * 0.97 / tris
        mod.use_collapse_triangulate = True
        select_only([obj], obj)
        bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.shade_smooth()
    return source, triangles(obj)


def ground_origin(obj):
    """Origin at ground level under the bbox centre; SINK of the height below it."""
    me = obj.data
    co = np.empty(len(me.vertices) * 3, dtype=np.float64)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    lo, hi = co.min(axis=0), co.max(axis=0)
    height = hi[2] - lo[2]
    pivot = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2] + SINK * height))
    me.transform(Matrix.Translation(-pivot))
    me.update()
    co -= np.array(pivot)
    size = hi - lo
    bm = bmesh.new()
    bm.from_mesh(me)
    open_z = [v.co.z for e in bm.edges if e.is_boundary for v in e.verts]
    bm.free()
    radius = float(np.sqrt(co[:, 0] ** 2 + co[:, 1] ** 2).max())
    # glTF +Y up: (x, y, z)_gltf = (x, z, -y)_blender
    size = [round(float(size[0]), 3), round(float(size[2]), 3), round(float(size[1]), 3)]
    open_above = sum(1 for z in open_z if z > 0.0) // 2
    return size, round(radius, 3), len(open_z) // 2, open_above


# ---------------------------------------------------------------- per asset

def build(asset_id):
    category, display, authors = ASSETS[asset_id]
    obj = import_asset(asset_id)
    src_tris, tris = decimate(obj, BUDGET[category])
    size, radius, open_edges, open_above = ground_origin(obj)

    tex = DOWNLOADS / asset_id / "textures"
    diff = load_rgba(tex / f"{asset_id}_diff_1k.jpg")
    nor = load_rgba(tex / f"{asset_id}_nor_gl_1k.jpg")
    arm_path = tex / f"{asset_id}_arm_1k.jpg"
    if arm_path.exists():
        orm = load_rgba(arm_path)
    else:
        orm = np.ones((TEX, TEX, 4), dtype=np.float32)
        orm[..., 1] = 0.85
    orm[..., 1] = np.maximum(orm[..., 1], ROUGH_FLOOR)
    orm[..., 2] = 0.0  # metallic
    grey, grey_mean = grey_base_colour(diff)

    mat = build_material(
        asset_id,
        save_image(f"{asset_id}_base", grey, "sRGB"),
        save_image(f"{asset_id}_normal", nor, "Non-Color"),
        save_image(f"{asset_id}_orm", orm, "Non-Color"),
    )
    obj.data.materials.append(mat)

    EXPORT.mkdir(parents=True, exist_ok=True)
    glb = EXPORT / f"{asset_id}.glb"
    obj.location = (0, 0, 0)
    select_only([obj], obj)
    bpy.ops.export_scene.gltf(
        filepath=str(glb), export_format="GLB", use_selection=True, export_yup=True, export_apply=True,
        export_texcoords=True, export_normals=True, export_tangents=False, export_materials="EXPORT",
        export_image_format="AUTO", export_vertex_color="NONE", export_attributes=False, export_extras=False,
        export_animations=False, export_skins=False, export_morph=False, export_cameras=False,
        export_lights=False,
    )
    print(f"[scanned] {asset_id}: {src_tris} -> {tris} triangles, size {size} m, grey mean {grey_mean:.3f}, "
          f"open edges {open_edges} ({open_above} above ground)")
    return obj, {
        "name": asset_id,
        "file": glb.name,
        "source_asset_id": asset_id,
        "source_name": display,
        "source_url": f"https://polyhaven.com/a/{asset_id}",
        "authors": authors,
        "licence": LICENCE,
        "category": category,
        "triangles": tris,
        "source_triangles": src_tris,
        "size_m": size,
        "footprint_radius_m": radius,
        "sink_m": round(SINK * size[1], 3),
        "open_edges": open_edges,
        "open_edges_above_ground": open_above,
        "base_colour_linear_mean": round(grey_mean, 3),
        "file_size_bytes": glb.stat().st_size,
    }


# ---------------------------------------------------------------- preview

def tint_material(mat):
    nt = mat.node_tree
    base = nt.nodes["base_colour"]
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    mix = nt.nodes.new("ShaderNodeMix")
    mix.name = mix.label = "preview_tint"
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.inputs["Factor"].default_value = 1.0
    mix.inputs[7].default_value = (*TINT, 1.0)  # B (colour)
    mix.location = (0, 300)
    nt.links.new(base.outputs["Color"], mix.inputs[6])  # A (colour)
    nt.links.new(mix.outputs[2], bsdf.inputs["Base Color"])


def setup_stage(scene):
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.use_denoising = True
    scene.render.image_settings.file_format = "PNG"
    world = bpy.data.worlds.new("preview_world")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.42, 0.47, 0.58, 1.0)
    bg.inputs["Strength"].default_value = 0.55
    scene.world = world

    bpy.ops.mesh.primitive_plane_add(size=400, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.name = "preview_ground"
    gm = bpy.data.materials.new("preview_ground")
    gm.use_nodes = True
    p = gm.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (0.42, 0.36, 0.31, 1.0)
    p.inputs["Roughness"].default_value = 1.0
    ground.data.materials.append(gm)

    sun_data = bpy.data.lights.new("preview_sun", "SUN")
    sun_data.energy = 4.5
    sun_data.angle = math.radians(1.5)
    sun = bpy.data.objects.new("preview_sun", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(90 - 16), 0.0, math.radians(-50))  # 16 degrees above the horizon

    cam_data = bpy.data.cameras.new("preview_camera")
    cam = bpy.data.objects.new("preview_camera", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    target = bpy.data.objects.new("preview_target", None)
    scene.collection.objects.link(target)
    track = cam.constraints.new("TRACK_TO")
    track.target = target
    track.track_axis = "TRACK_NEGATIVE_Z"
    track.up_axis = "UP_Y"
    return cam, target


def aim(cam, target, centre, width, height, elev_deg, azim_deg, lens=40.0, aspect=16 / 9):
    cam.data.lens = lens
    fov = 2 * math.atan(36.0 / 2 / lens)  # horizontal, sensor 36 mm
    vfov = 2 * math.atan(math.tan(fov / 2) / aspect)
    dist = max(width / 2 / math.tan(fov / 2), height / 2 / math.tan(vfov / 2)) * 1.06
    e, a = math.radians(elev_deg), math.radians(azim_deg)
    target.location = centre
    cam.location = Vector(centre) + dist * Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e)))


def preview(objs, rows):
    scene = bpy.context.scene
    cam, target = setup_stage(scene)
    for obj in objs:
        tint_material(obj.data.materials[0])
    # in a row along X, largest first, gaps proportional to the neighbours
    x = 0.0
    for obj, row in zip(objs, rows):
        w = row["size_m"][0]
        gap = max(0.4, 0.15 * w)
        obj.location = (x + w / 2, 0.0, 0.0)
        x += w + gap
    total = x
    top = max(r["size_m"][1] for r in rows)
    scene.render.resolution_x, scene.render.resolution_y = 1600, 900
    scene.cycles.samples = 48
    aim(cam, target, (total / 2, 0, top * 0.3), total, top, 11, 0)
    scene.render.filepath = str(EXPORT / "preview.png")
    bpy.ops.render.render(write_still=True)

    if QA_DIR:
        QA_DIR.mkdir(parents=True, exist_ok=True)
        scene.render.resolution_x, scene.render.resolution_y = 720, 405
        scene.cycles.samples = 16
        for obj, row in zip(objs, rows):
            for o in objs:
                o.hide_render = o is not obj
            sx, sy, sz = row["size_m"]
            c = obj.location
            span = max(sx, sz) * 1.1
            for tag, elev, azim in (("side", 22, 35), ("top", 75, 10), ("back", 25, 200)):
                aim(cam, target, (c.x, c.y, sy * 0.3), span, sy + 0.2 * span, elev, azim)
                scene.render.filepath = str(QA_DIR / f"{row['name']}_{tag}.png")
                bpy.ops.render.render(write_still=True)
        for o in objs:
            o.hide_render = False
    aim(cam, target, (total / 2, 0, top * 0.3), total, top, 11, 0)


# ---------------------------------------------------------------- main

def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.filepaths.save_version = 0
    for folder, pattern in ((EXPORT, "*.glb"), (TEXTURES, "*.jpg")):  # outputs of this script only
        for old in folder.glob(pattern):
            old.unlink()
    objs, rows = [], []
    for asset_id in ASSETS:
        if asset_id in DROPPED:
            continue
        obj, row = build(asset_id)
        objs.append(obj)
        rows.append(row)
        over = row["triangles"] > BUDGET[row["category"]]
        assert not over, f"{asset_id}: {row['triangles']} triangles over budget"

    manifest = {
        "generator": "tools/nova/build_scanned_rocks.py",
        "up_axis": "+Y",
        "units": "metres",
        "sink_share_of_height": SINK,
        "textures": "base colour (grey, sRGB), normal (OpenGL), ORM (R occlusion, G roughness, B metallic 0), "
                    f"{TEX} px, embedded",
        "budgets": BUDGET,
        "dropped": DROPPED,
        "models": rows,
    }
    (EXPORT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    lines = ["Scanned rock models used by Nova (Dying Star). All from Poly Haven, licence CC0 1.0.", ""]
    for asset_id in ASSETS:
        if asset_id in DROPPED:
            continue
        _, display, authors = ASSETS[asset_id]
        lines.append(f"{display} - {authors} - Poly Haven, CC0 - https://polyhaven.com/a/{asset_id}")
    lines += ["", "Changes: base colour converted to grey and contrast-stretched to a light mid-grey "
              "(tinted in game), meshes decimated (collapse) and re-origined at ground level, "
              "textures resized to 1024 px, ambient occlusion / roughness packed into one ORM texture "
              "(metallic 0), all embedded in one GLB per model."]
    (EXPORT / "SOURCES.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

    preview(objs, rows)
    bpy.ops.wm.save_as_mainfile(filepath=str(BASE / "scanned_rocks.blend"))
    total = sum(r["file_size_bytes"] for r in rows)
    print(f"[scanned] {len(rows)} models, GLB total {total} bytes")


main()
