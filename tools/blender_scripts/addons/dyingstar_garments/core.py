"""Blender to the game: the reference body and a garment as arrays, the binding, the export.

Single responsibility: everything that is not UI. The binding itself is garment_bind.py, the game's rules
garment_rules.py (tools/character/garments): the zip ships copies of both; run from the repository, the addon
reads them there.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import bpy
import numpy as np

try:
    from . import garment_bind as gb  # the copy the zip ships
    from . import garment_rules as rules
except ImportError:  # run from the repository: tools/blender_scripts/addons/dyingstar_garments -> tools/character
    sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "character" / "garments"))
    import garment_bind as gb  # noqa: E402
    import garment_rules as rules  # noqa: E402

BODY_PROP = "ds_body_signature"
SKIN_GROUP = "DS_Skin"
HIDE_PREFIX = "DS_Hide_"
CHECK_ATTRIBUTE = "DS_Check"
GENDER_KEYS = {"male": "Gender_Male", "female": "Gender_Female"}
SKULL_BONES = ("Head", "Neck")


def to_game(p):
    """Blender (Z up, facing -Y) -> the game's frame (Y up, facing +Z)."""
    p = np.asarray(p, dtype=np.float64)
    return np.column_stack([p[:, 0], p[:, 2], -p[:, 1]])


def to_blender(p):
    p = np.asarray(p, dtype=np.float64)
    return np.column_stack([p[:, 0], -p[:, 2], p[:, 1]])


def find_body(scene=None):
    """The reference body in the scene (the object carrying ds_body_signature), or None."""
    for obj in (scene or bpy.context.scene).objects:
        if obj.type == "MESH" and BODY_PROP in obj:
            return obj
    return None


def _key_coords(mesh, name):
    keys = mesh.shape_keys
    block = keys.key_blocks.get(name) if keys else None
    if block is None:
        return None
    out = np.zeros(len(mesh.vertices) * 3, dtype=np.float32)
    block.data.foreach_get("co", out)
    return out.reshape(-1, 3).astype(np.float64)


def body_points(body, which="neutral", mix=False):
    """The body's vertices in the game's frame, at rest: the base plus the chosen gender (which), or the shape keys
    as they are set in the scene (mix: to try the garment on another body)."""
    mesh = body.data
    basis = _key_coords(mesh, "Basis")
    if basis is None:
        basis = np.zeros(len(mesh.vertices) * 3, dtype=np.float32)
        mesh.vertices.foreach_get("co", basis)
        basis = basis.reshape(-1, 3).astype(np.float64)
    pts = basis.copy()
    if mix and mesh.shape_keys:
        for block in mesh.shape_keys.key_blocks[1:]:
            if block.value != 0.0 and not block.mute:
                pts += block.value * (_key_coords(mesh, block.name) - basis)
    elif which in GENDER_KEYS:
        shaped = _key_coords(mesh, GENDER_KEYS[which])
        if shaped is not None:
            pts = shaped
    return to_game(pts)


def _group_weights(obj, names):
    """{group name: dense weights per vertex} for the named vertex groups of obj."""
    index = {obj.vertex_groups[n].index: n for n in names if n in obj.vertex_groups}
    out = {n: np.zeros(len(obj.data.vertices)) for n in index.values()}
    for v in obj.data.vertices:
        for g in v.groups:
            if g.group in index:
                out[index[g.group]][v.index] = g.weight
    return out


def make_body(body, which="neutral") -> "gb.Body":
    """The reference body as garment_bind sees it: points, triangles, skin, bone weights in the game's bone order."""
    mesh = body.data
    mesh.calc_loop_triangles()
    tris = np.zeros(len(mesh.loop_triangles) * 3, dtype=np.int32)
    mesh.loop_triangles.foreach_get("vertices", tris)
    names = list(body.get("ds_bone_names", []))
    groups = _group_weights(body, names + [SKIN_GROUP])
    skin = groups.pop(SKIN_GROUP, np.ones(len(mesh.vertices))) > 0.5
    dense = np.zeros((len(mesh.vertices), max(len(names), 1)))
    for b, name in enumerate(names):
        if name in groups:
            dense[:, b] = groups[name]
    bones, weights = gb.top4(dense)
    return gb.Body(body_points(body, which), tris.reshape(-1, 3), skin, bones, weights, len(names),
                   str(body[BODY_PROP]))


def garment_arrays(obj, depsgraph):
    """(points in the game's frame, triangles, per-corner UVs) of the garment as evaluated (its modifiers applied)."""
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        mesh.calc_loop_triangles()
        co = np.zeros(len(mesh.vertices) * 3, dtype=np.float32)
        mesh.vertices.foreach_get("co", co)
        world = np.array(obj.matrix_world, dtype=np.float64)
        pts = co.reshape(-1, 3).astype(np.float64) @ world[:3, :3].T + world[:3, 3]
        tris = np.zeros(len(mesh.loop_triangles) * 3, dtype=np.int32)
        mesh.loop_triangles.foreach_get("vertices", tris)
        uv = None
        if mesh.uv_layers.active is not None:
            loops = np.zeros(len(mesh.loop_triangles) * 3, dtype=np.int32)
            mesh.loop_triangles.foreach_get("loops", loops)
            all_uv = np.zeros(len(mesh.loops) * 2, dtype=np.float32)
            mesh.uv_layers.active.data.foreach_get("uv", all_uv)
            uv = all_uv.reshape(-1, 2)[loops].astype(np.float64)
        if np.linalg.det(world[:3, :3]) < 0:  # a mirrored object turns its triangles inside out
            tris = tris.reshape(-1, 3)[:, [0, 2, 1]].reshape(-1)
            if uv is not None:
                uv = uv.reshape(-1, 3, 2)[:, [0, 2, 1]].reshape(-1, 2)
        return to_game(pts), tris.reshape(-1, 3), uv
    finally:
        evaluated.to_mesh_clear()


def skull_options(body, gbody):
    """(allowed body vertices, scale pairs) of a garment hung on the skull: the head's and neck's skin, the head's
    width / height / depth measured between its extreme vertices."""
    groups = _group_weights(body, list(SKULL_BONES))
    head = groups.get("Head", np.zeros(len(gbody.points)))
    neck = groups.get("Neck", np.zeros(len(gbody.points)))
    allowed = gbody.skin_mask & ((head + neck) >= 0.5)
    ids = np.nonzero(gbody.skin_mask & (head >= 0.5))[0]
    if len(ids) == 0:
        return allowed, None
    p = gbody.points[ids]
    pairs = np.array([[ids[np.argmin(p[:, a])], ids[np.argmax(p[:, a])]] for a in range(3)])
    return allowed, pairs


def hide_group(body, garment_id):
    return body.vertex_groups.get(HIDE_PREFIX + garment_id)


def bind_garment(context, obj):
    """Bind the garment object on the reference body: (arrays, report, body object). Raises ValueError for the
    artist when something is missing."""
    body = find_body(context.scene)
    if body is None:
        raise ValueError("No reference body in the scene: Load the reference body first")
    if obj is None or obj.type != "MESH" or obj == body:
        raise ValueError("Select the garment (a mesh, not the body)")
    props = obj.ds_garment
    gbody = make_body(body, context.scene.ds_garment_body)
    points, tris, uv = garment_arrays(obj, context.evaluated_depsgraph_get())
    if len(tris) == 0:
        raise ValueError("The garment has no faces")
    allowed, pairs = (None, None)
    if props.binding == "skull":
        allowed, pairs = skull_options(body, gbody)
    hide = None
    group = hide_group(body, props.garment_id) if props.garment_id else None
    if group is not None:  # painted by hand (Hidden skin), else found under the garment
        hide = (_group_weights(body, [group.name])[group.name] > 0.5) & gbody.skin_mask
    arrays, report = gb.bind(points, tris, uv, gbody, layer=int(props.layer), allowed=allowed, scale_pairs=pairs,
                             hide=hide)
    return arrays, report, body


def show_report(obj, report):
    """The check in the panel, and on the mesh: colour attribute DS_Check, red inside the skin, orange too close."""
    props = obj.ds_garment
    props.checked = True
    props.poke_share = 100.0 * report["poke_share"]
    props.close_share = 100.0 * report["close_share"]
    props.hidden_skin = report["hidden_skin"]
    props.triangles = report["triangles"]
    mesh = obj.data
    if len(mesh.vertices) != report["vertices"]:
        return  # modifiers change the vertex count: the colours cannot go on the base mesh
    attr = mesh.color_attributes.get(CHECK_ATTRIBUTE) or mesh.color_attributes.new(CHECK_ATTRIBUTE, "BYTE_COLOR",
                                                                                    "POINT")
    colours = np.tile(np.array([0.2, 0.8, 0.3, 1.0]), (len(mesh.vertices), 1))
    colours[report["close"]] = (1.0, 0.55, 0.0, 1.0)
    colours[report["poke"]] = (1.0, 0.0, 0.0, 1.0)
    attr.data.foreach_set("color", colours.reshape(-1))


def write_hide_group(body, garment_id, hidden):
    group = hide_group(body, garment_id) or body.vertex_groups.new(name=HIDE_PREFIX + garment_id)
    group.remove(list(range(len(body.data.vertices))))
    group.add(np.nonzero(hidden)[0].tolist(), 1.0, "REPLACE")
    return group


def preview_on_body(context, name, arrays, materials=()):
    """The garment put back on the body as its shape keys are set now, by the game's own rule: a mesh named name."""
    body = find_body(context.scene)
    points = gb.fit(body_points(body, mix=True), arrays)
    old = bpy.data.objects.get(name)
    if old is not None:
        bpy.data.objects.remove(old, do_unlink=True)
    src = arrays["vertex"]
    tris = src[arrays["index"]].reshape(-1, 3)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(to_blender(points).tolist(), [], tris.tolist())
    mesh.update()
    preview = bpy.data.objects.new(name, mesh)
    for mat in materials:
        mesh.materials.append(mat)
    context.scene.collection.objects.link(preview)
    return preview


# --- export ------------------------------------------------------------------------------------------------------

TEXTURE_CAPS = {"albedo": 2048, "normal": 2048, "ao": 1024, "tint": 1024}


def find_textures(obj):
    """{role: bpy image} from the garment's first material: Base Color -> albedo, the Normal Map node's image ->
    normal; images whose node label or name says ao / tint -> those."""
    out = {}
    mat = obj.active_material
    if mat is None or not mat.use_nodes:
        return out
    for node in mat.node_tree.nodes:
        if node.type != "TEX_IMAGE" or node.image is None:
            continue
        tag = (node.label or node.image.name).lower()
        if "tint" in tag:
            out["tint"] = node.image
        elif "ao" in tag.replace(".", "_").split("_") or "occlusion" in tag:
            out["ao"] = node.image
        else:
            for link in node.outputs["Color"].links:
                to = link.to_node
                if to.type == "BSDF_PRINCIPLED" and link.to_socket.name == "Base Color":
                    out["albedo"] = node.image
                elif to.type == "NORMAL_MAP":
                    out["normal"] = node.image
    return out


def save_texture(image, path, cap):
    """The image as WebP at path, at most cap pixels wide."""
    copy = image.copy()
    try:
        w, h = copy.size
        if max(w, h) > cap:
            s = cap / max(w, h)
            copy.scale(max(1, int(w * s)), max(1, int(h * s)))
        copy.filepath_raw = str(path)
        copy.file_format = "WEBP"
        copy.save()
    finally:
        bpy.data.images.remove(copy)


def credit_line(props, prefs):
    if props.credit == "discord":
        if not prefs or not prefs.discord_pseudo or not prefs.discord_id:
            raise ValueError("Set your Discord pseudo and id in the addon's Preferences")
        return "Discord - %s - %s\n" % (prefs.discord_pseudo, prefs.discord_id)
    if not (props.credit_site and props.credit_author and props.credit_url and props.credit_licence):
        raise ValueError("A third-party credit needs its site, author, URL and licence")
    return "%s - %s - %s - %s\n" % (props.credit_site, props.credit_author, props.credit_url, props.credit_licence)


def problems(props):
    """What stops an export, for the artist."""
    out = []
    gid = props.garment_id
    if not gid or not all(c.islower() or c.isdigit() or c == "_" for c in gid) or not gid[0].isalpha():
        out.append("Id: lowercase letters, digits and _, starting with a letter")
    if not props.name_en or not props.name_fr:
        out.append("Give it an English and a French name")
    out += ["GDD code: " + e for e in rules.check_item(props.item())]
    return out


def export_garment(context, obj, root: Path, prefs):
    """Bind and write the garment into the project: its file, textures, credit, catalogue entry and names.
    Returns (folder, report)."""
    props = obj.ds_garment
    issues = problems(props)
    if issues:
        raise ValueError("; ".join(issues))
    credit = credit_line(props, prefs)
    arrays, report, body = bind_garment(context, obj)
    show_report(obj, report)
    if not report["ok"]:
        raise ValueError("%.1f %% of it is inside the skin (at most %.0f %%): see the red in DS_Check"
                         % (100 * report["poke_share"], 100 * gb.MAX_POKE_SHARE))
    gid = props.garment_id
    folder = root / "assets" / "_universe" / "characters" / "human" / "garments" / gid
    folder.mkdir(parents=True, exist_ok=True)
    meta = dict(props.item(), hides=props.hides(), material=props.material, gender=props.gender,
                binding=props.binding, name_en=props.name_en, name_fr=props.name_fr,
                bound_on=context.scene.ds_garment_body, body_signature=str(body[BODY_PROP]))
    gb.write_garment(str(folder / (gid + ".dsgarment")), arrays, meta)
    for role, image in find_textures(obj).items():
        save_texture(image, folder / ("%s_%s.webp" % (gid, role)), TEXTURE_CAPS[role])
    (folder / (gid + ".txt")).write_text(credit, encoding="utf-8")
    labels = _labels_module(root)
    labels.add_to_catalogue(str(root), meta)
    labels.write_labels(str(root))
    return folder, report


def _labels_module(root: Path):
    """tools/character/garments/garment_labels.py of the project the garment goes to (its catalogue rules)."""
    path = str(root / "tools" / "character" / "garments")
    if path not in sys.path:
        sys.path.insert(0, path)
    import importlib
    import garment_labels  # noqa: E402
    return importlib.reload(garment_labels)


def read_catalogue(root: Path) -> dict:
    return json.loads((root / "assets" / "_universe" / "characters" / "human" / "human_catalogue.json")
                      .read_text(encoding="utf-8"))


def load_garment_preview(context, root: Path, garment_id):
    """An exported garment, put on the body as it is now (to see a jacket over a T-shirt): a mesh named after it."""
    arrays, meta = gb.read_garment(os.path.join(root, "assets", "_universe", "characters", "human", "garments",
                                                garment_id, garment_id + ".dsgarment"))
    body = find_body(context.scene)
    if str(body[BODY_PROP]) != meta.get("body_signature"):
        raise ValueError("%s was bound to another body (%s)" % (garment_id, meta.get("body_signature")))
    return preview_on_body(context, "DS_worn_" + garment_id, arrays)
