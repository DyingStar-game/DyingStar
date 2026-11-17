"""The dyingstar_garments addon end to end, in Blender without a window: install its zip, load the reference body,
dress it in a garment the game already has (as an artist would have modelled it), check it, export it into a copy
of the project's catalogue, and read the export back.

usage: blender -b --factory-startup --python tools/blender_scripts/test_garments_addon.py -- \
           <dyingstar_garments zip> <vitruvian_reference.blend> <project root> <scratch folder>
Prints "ADDON TEST OK" and exits 0, or the failure and exits 1. The project is only read: the export goes to a copy
of the files it writes, in the scratch folder.
"""
import json
import os
import shutil
import sys
import traceback

import bpy
import numpy as np


def main():
    zip_path, reference, project, scratch = [os.path.abspath(a) for a in sys.argv[sys.argv.index("--") + 1:][:4]]
    root = os.path.join(scratch, "project")
    shutil.rmtree(root, ignore_errors=True)
    for rel in ("assets/_universe/characters/human/human_catalogue.json", "test/data/character/catalogue_order.json",
                "tools/localization/localisation.csv"):
        os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
        shutil.copy(os.path.join(project, rel), os.path.join(root, rel))
    shutil.copytree(os.path.join(project, "tools/character/garments"), os.path.join(root, "tools/character/garments"))
    shutil.copytree(os.path.join(project, "assets/_universe/characters/human/garments"),
                    os.path.join(root, "assets/_universe/characters/human/garments"),
                    ignore=shutil.ignore_patterns("*.import", "*.webp"))

    bpy.ops.preferences.addon_install(filepath=zip_path, overwrite=True)
    bpy.ops.preferences.addon_enable(module="dyingstar_garments")
    import dyingstar_garments.core as core  # noqa: E402  (the zip's copy, with its own garment_bind)
    gb = core.gb
    prefs = bpy.context.preferences.addons["dyingstar_garments"].preferences
    prefs.reference_blend = reference
    prefs.project_root = root
    prefs.discord_pseudo, prefs.discord_id = "tester", "123456789"

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.preferences.addon_enable(module="dyingstar_garments")
    prefs = bpy.context.preferences.addons["dyingstar_garments"].preferences
    prefs.reference_blend, prefs.project_root = reference, root
    prefs.discord_pseudo, prefs.discord_id = "tester", "123456789"
    assert bpy.ops.dyingstar.garment_load_body() == {"FINISHED"}, "load the body"
    scene = bpy.context.scene
    scene.ds_garment_body = "male"
    assert bpy.ops.dyingstar.garment_set_body() == {"FINISHED"}
    body = core.find_body(scene)

    # The garment an artist would have modelled: the men's T-shirt and jeans, on the man, at rest.
    arrays, meta = gb.read_garment(os.path.join(project, "assets/_universe/characters/human/garments",
                                                "mh_male_casualsuit04", "mh_male_casualsuit04.dsgarment"))
    gbody = core.make_body(body, "male")
    points = gb.fit(gbody.points, arrays)
    tris = arrays["vertex"][arrays["index"]].reshape(-1, 3)
    mesh = bpy.data.meshes.new("tshirt")
    mesh.from_pydata(core.to_blender(points).tolist(), [], tris.tolist())
    uv = arrays["uv"][arrays["index"]].astype(np.float64)
    uv[:, 1] = 1.0 - uv[:, 1]
    layer = mesh.uv_layers.new(name="UVMap")
    layer.data.foreach_set("uv", uv.astype(np.float32).reshape(-1))
    mesh.update()
    obj = bpy.data.objects.new("tshirt", mesh)
    scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    p = obj.ds_garment
    p.garment_id, p.name_en, p.name_fr = "test_tshirt_jeans", "Test T-shirt", "T-shirt de test"
    p.zone, p.extra_zones, p.support, p.layer, p.blocks = "3", "4, 8", "0", "1", True
    assert core.rules.code_of(p.item()) == "3-0-1-0", core.rules.code_of(p.item())
    assert bpy.ops.dyingstar.garment_check() == {"FINISHED"}
    assert p.checked and p.poke_share < 6.0, "check: %.2f %% inside the skin" % p.poke_share
    assert mesh.color_attributes.get(core.CHECK_ATTRIBUTE) is not None, "the check colours the mesh"
    assert bpy.ops.dyingstar.garment_hidden_skin() == {"FINISHED"}
    assert core.hide_group(body, "test_tshirt_jeans") is not None
    assert bpy.ops.dyingstar.garment_preview() == {"FINISHED"}
    assert bpy.data.objects.get("tshirt_DS_preview") is not None
    obj.hide_set(False)
    bpy.context.view_layer.objects.active = obj
    assert bpy.ops.dyingstar.garment_export() == {"FINISHED"}, "export"

    folder = os.path.join(root, "assets/_universe/characters/human/garments/test_tshirt_jeans")
    out, out_meta = gb.read_garment(os.path.join(folder, "test_tshirt_jeans.dsgarment"))
    back = gb.fit(gbody.points, out)
    err = float(np.abs(back - points).max())
    assert err < 1e-5, "the exported garment sits where it was modelled (%.2e m off)" % err
    assert out_meta["body_signature"] == str(body[core.BODY_PROP]) == meta["body_signature"], "same body as the game's"
    assert out_meta["zones"] == ["3", "4", "8"] and out_meta["access"] == 0 and out_meta["bound_on"] == "male"
    assert open(os.path.join(folder, "test_tshirt_jeans.txt")).read() == "Discord - tester - 123456789\n"
    cat = json.load(open(os.path.join(root, "assets/_universe/characters/human/human_catalogue.json")))
    assert cat["garments"][-1]["id"] == "test_tshirt_jeans", "appended at the end of the catalogue"
    order = json.load(open(os.path.join(root, "test/data/character/catalogue_order.json")))
    assert order["garments"][-1] == "test_tshirt_jeans"
    csv = open(os.path.join(root, "tools/localization/localisation.csv"), encoding="utf-8").read()
    assert "%%GARMENT_TEST_TSHIRT_JEANS,Test T-shirt,T-shirt de test" in csv
    hidden_old = set(arrays["delete"].tolist())
    hidden_new = set(out["delete"].tolist())
    print("ADDON hidden skin: MakeHuman %d, found %d, common %d" % (len(hidden_old), len(hidden_new),
                                                                     len(hidden_old & hidden_new)))
    print("ADDON TEST OK (%.2f %% inside the skin, %d triangles, %.1e m)" % (p.poke_share, p.triangles, err))


try:
    main()
except Exception:
    traceback.print_exc()
    print("ADDON TEST FAILED")
    sys.exit(1)
