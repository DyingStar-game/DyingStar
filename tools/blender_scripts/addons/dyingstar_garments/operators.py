"""The panel's buttons.

Single responsibility: turn a click into a call to core, and its outcome into a message for the artist.
"""

from __future__ import annotations

import bpy

from . import core, preferences


def _garment(context):
    obj = context.active_object
    if obj is None or obj.type != "MESH" or core.BODY_PROP in obj:
        return None
    return obj


class DYINGSTAR_OT_garment_load_body(bpy.types.Operator):
    """Append the game's body (and its bones) from the reference .blend set in the Preferences"""

    bl_idname = "dyingstar.garment_load_body"
    bl_label = "Load the reference body"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        if core.find_body(context.scene) is not None:
            self.report({"INFO"}, "The reference body is already in the scene")
            return {"CANCELLED"}
        path = preferences.reference_blend()
        if path is None:
            self.report({"ERROR"}, "Set the reference body (vitruvian_reference.blend) in the addon's Preferences")
            return {"CANCELLED"}
        with bpy.data.libraries.load(str(path), link=False) as (data_from, data_to):
            data_to.objects = [n for n in data_from.objects if n in ("DS_Body", "DS_Rig")]
        collection = bpy.data.collections.new("DS Reference")
        context.scene.collection.children.link(collection)
        for obj in data_to.objects:
            if obj is not None:
                collection.objects.link(obj)
        body = core.find_body(context.scene)
        if body is not None:
            body.hide_select = True  # model around it without picking it by mistake
        self.report({"INFO"}, "Reference body loaded: model the garment around it, at rest (A pose)")
        return {"FINISHED"}


class DYINGSTAR_OT_garment_set_body(bpy.types.Operator):
    """Show the body the garment is modelled on (neutral, a man, a woman), every other shape at rest"""

    bl_idname = "dyingstar.garment_set_body"
    bl_label = "Show the body to model on"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        body = core.find_body(context.scene)
        if body is None or body.data.shape_keys is None:
            self.report({"ERROR"}, "No reference body in the scene")
            return {"CANCELLED"}
        which = context.scene.ds_garment_body
        for block in body.data.shape_keys.key_blocks[1:]:
            block.value = 1.0 if block.name == core.GENDER_KEYS.get(which) else 0.0
        for obj in list(context.scene.objects):
            if obj.name.endswith("_DS_preview") or obj.name.startswith("DS_worn_"):
                bpy.data.objects.remove(obj, do_unlink=True)
        return {"FINISHED"}


class DYINGSTAR_OT_garment_check(bpy.types.Operator):
    """Bind the garment and check it: how much is inside the skin (red in DS_Check), too close for its layer (orange)"""

    bl_idname = "dyingstar.garment_check"
    bl_label = "Check"

    def execute(self, context):
        obj = _garment(context)
        try:
            _arrays, report, _body = core.bind_garment(context, obj)
        except ValueError as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        core.show_report(obj, report)
        level = {"INFO"} if report["ok"] else {"WARNING"}
        self.report(level, "%.1f %% inside the skin, %.1f %% too close for layer %s, %d skin vertices hidden"
                    % (100 * report["poke_share"], 100 * report["close_share"], obj.ds_garment.layer,
                       report["hidden_skin"]))
        return {"FINISHED"}


class DYINGSTAR_OT_garment_hidden_skin(bpy.types.Operator):
    """Find the skin under the garment into the body's vertex group DS_Hide_<id>, to paint by hand if need be
    (the export uses the group when it exists)"""

    bl_idname = "dyingstar.garment_hidden_skin"
    bl_label = "Hidden skin to a group"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        obj = _garment(context)
        if obj is None or not obj.ds_garment.garment_id:
            self.report({"ERROR"}, "Select the garment and give it its id first")
            return {"CANCELLED"}
        body = core.find_body(context.scene)
        old = core.hide_group(body, obj.ds_garment.garment_id)
        if old is not None:
            body.vertex_groups.remove(old)  # found again, not read back
        try:
            arrays, _report, body = core.bind_garment(context, obj)
        except ValueError as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        hidden = [False] * len(body.data.vertices)
        for v in arrays["delete"]:
            hidden[int(v)] = True
        group = core.write_hide_group(body, obj.ds_garment.garment_id, hidden)
        self.report({"INFO"}, "%d skin vertices in %s" % (len(arrays["delete"]), group.name))
        return {"FINISHED"}


class DYINGSTAR_OT_garment_preview(bpy.types.Operator):
    """Put the garment on the body as its shape keys are set now (fat, thin, a woman...), by the game's own rule"""

    bl_idname = "dyingstar.garment_preview"
    bl_label = "Try on this body"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        obj = _garment(context)
        try:
            arrays, _report, _body = core.bind_garment(context, obj)
        except ValueError as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        core.preview_on_body(context, obj.name + "_DS_preview", arrays, obj.data.materials)
        obj.hide_set(True)
        self.report({"INFO"}, "Shown on the body as set: Show the body to model on puts it back")
        return {"FINISHED"}


class DYINGSTAR_OT_garment_wear(bpy.types.Operator):
    """Put an exported garment of the project on the body, to see this one over or under it"""

    bl_idname = "dyingstar.garment_wear"
    bl_label = "Wear an exported garment"
    bl_options = {"REGISTER", "UNDO"}

    garment: bpy.props.StringProperty(name="Garment id")

    def invoke(self, context, event):
        return context.window_manager.invoke_props_dialog(self)

    def execute(self, context):
        root = preferences.project_root()
        if root is None or core.find_body(context.scene) is None:
            self.report({"ERROR"}, "Set the project in the Preferences and load the reference body")
            return {"CANCELLED"}
        try:
            core.load_garment_preview(context, root, self.garment.strip())
        except (OSError, ValueError, KeyError) as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        return {"FINISHED"}


class DYINGSTAR_OT_garment_export(bpy.types.Operator):
    """Bind the garment and write it into the project: <id>.dsgarment, its textures (WebP), its credit, its catalogue
    entry and its names. Godot imports it on its next scan"""

    bl_idname = "dyingstar.garment_export"
    bl_label = "Export to the game"

    def execute(self, context):
        root = preferences.project_root()
        if root is None:
            self.report({"ERROR"}, "Set the DyingStar project folder in the addon's Preferences")
            return {"CANCELLED"}
        obj = _garment(context)
        try:
            folder, report = core.export_garment(context, obj, root, preferences.prefs())
        except ValueError as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        self.report({"INFO"}, "Exported to %s (%.1f %% inside the skin)" % (folder, 100 * report["poke_share"]))
        return {"FINISHED"}


CLASSES = (DYINGSTAR_OT_garment_load_body, DYINGSTAR_OT_garment_set_body, DYINGSTAR_OT_garment_check,
           DYINGSTAR_OT_garment_hidden_skin, DYINGSTAR_OT_garment_preview, DYINGSTAR_OT_garment_wear,
           DYINGSTAR_OT_garment_export)


def register() -> None:
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister() -> None:
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)
