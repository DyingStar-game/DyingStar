"""The panel: 3D View > Sidebar > DyingStar.

Single responsibility: lay out the garment's fields and the buttons, in the order an artist works: the body, the
garment's description, the checks, the export. No logic: every action is an operator.
"""

from __future__ import annotations

import bpy

from . import core, preferences


class DYINGSTAR_PT_garment(bpy.types.Panel):
    bl_label = "Garment"
    bl_idname = "DYINGSTAR_PT_garment"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "DyingStar"

    def draw(self, context):
        layout = self.layout
        body = core.find_body(context.scene)
        box = layout.box()
        box.label(text="1. Body", icon="ARMATURE_DATA")
        if body is None:
            box.operator("dyingstar.garment_load_body", icon="IMPORT")
            if preferences.reference_blend() is None:
                box.label(text="Set the reference body in Preferences", icon="ERROR")
            return
        row = box.row(align=True)
        row.prop(context.scene, "ds_garment_body", text="")
        row.operator("dyingstar.garment_set_body", text="", icon="FILE_REFRESH")
        box.label(text="Body %s" % body[core.BODY_PROP], icon="CHECKMARK")

        obj = context.active_object
        if obj is None or obj.type != "MESH" or core.BODY_PROP in obj:
            layout.label(text="Select the garment's mesh", icon="INFO")
            return
        props = obj.ds_garment
        box = layout.box()
        box.label(text="2. Garment", icon="MOD_CLOTH")
        box.prop(props, "garment_id")
        box.prop(props, "name_en")
        box.prop(props, "name_fr")
        col = box.column(align=True)
        col.label(text="GDD code  %s" % core.rules.code_of(props.item()))
        row = col.row(align=True)
        row.prop(props, "zone", text="")
        if props.zone in "456789":
            row.prop(props, "side", text="")
        if props.zone in "57":
            row.prop(props, "finger", text="")
        col.prop(props, "extra_zones")
        col.prop(props, "support")
        col.prop(props, "layer")
        col.prop(props, "blocks")
        row = box.row(align=True)
        row.prop(props, "hides_hair", toggle=True)
        row.prop(props, "hides_beard", toggle=True)
        row.prop(props, "hides_face", toggle=True)
        box.prop(props, "material")
        box.prop(props, "binding")
        box.prop(props, "gender")

        box = layout.box()
        box.label(text="3. Check", icon="VIEWZOOM")
        row = box.row(align=True)
        row.operator("dyingstar.garment_check", icon="CHECKBOX_HLT")
        row.operator("dyingstar.garment_hidden_skin", icon="GROUP_VERTEX")
        row = box.row(align=True)
        row.operator("dyingstar.garment_preview", icon="HIDE_OFF")
        row.operator("dyingstar.garment_wear", icon="MOD_CLOTH")
        if props.checked:
            col = box.column(align=True)
            col.label(text="Inside the skin: %.1f %% (max %.0f %%)" % (props.poke_share, 100 * core.gb.MAX_POKE_SHARE),
                      icon="ERROR" if props.poke_share > 100 * core.gb.MAX_POKE_SHARE else "CHECKMARK")
            col.label(text="Closer than %.0f mm: %.1f %%" % (1000 * core.gb.LAYER_CLEARANCE[int(props.layer)],
                                                               props.close_share))
            col.label(text="Skin hidden: %d vertices   Triangles: %d" % (props.hidden_skin, props.triangles),
                      icon="ERROR" if props.triangles > 6000 else "NONE")

        box = layout.box()
        box.label(text="4. Export", icon="EXPORT")
        box.prop(props, "credit")
        if props.credit == "third":
            box.prop(props, "credit_site")
            box.prop(props, "credit_author")
            box.prop(props, "credit_url")
            box.prop(props, "credit_licence")
        for issue in core.problems(props):
            box.label(text=issue, icon="ERROR")
        box.operator("dyingstar.garment_export", icon="EXPORT")
        if preferences.project_root() is None:
            box.label(text="Set the DyingStar project in Preferences", icon="ERROR")


def register() -> None:
    bpy.utils.register_class(DYINGSTAR_PT_garment)


def unregister() -> None:
    bpy.utils.unregister_class(DYINGSTAR_PT_garment)
