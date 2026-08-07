bl_info = {
    "name": "Root Motion Toggle",
    "author": "Quaternius",
    "version": (1, 0, 0),
    "blender": (4, 5, 0),
    "location": "View3D > Sidebar > Root Motion",
    "description": "Enable or disable root motion muting across all animations",
    "category": "Animation",
}

import bpy


def set_root_motion_mute(mute: bool):
    actions_affected = 0

    for action in bpy.data.actions:
        group = action.groups.get("root")
        if group is not None:
            group.mute = mute
            for fcurve in action.fcurves:
                if fcurve.group == group:
                    fcurve.mute = mute
            actions_affected += 1

    return actions_affected


class ROOTMOTION_OT_enable_all(bpy.types.Operator):
    bl_idname = "rootmotion.enable_all"
    bl_label = "Enable All Root Motion"
    bl_description = "Unmute the root bone channel group in all animations"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        actions = set_root_motion_mute(False)
        self.report({'INFO'}, f"Root motion enabled across {actions} action(s)")
        return {'FINISHED'}


class ROOTMOTION_OT_disable_all(bpy.types.Operator):
    bl_idname = "rootmotion.disable_all"
    bl_label = "Disable All Root Motion"
    bl_description = "Mute the root bone channel group in all animations"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        actions = set_root_motion_mute(True)
        self.report({'INFO'}, f"Root motion disabled across {actions} action(s)")
        return {'FINISHED'}


class ROOTMOTION_PT_panel(bpy.types.Panel):
    bl_label = "Root Motion"
    bl_idname = "ROOTMOTION_PT_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Root Motion"

    def draw(self, context):
        layout = self.layout
        col = layout.column(align=True)
        col.scale_y = 1.4
        col.operator("rootmotion.enable_all", text="Enable All Root Motion", icon='PLAY')
        col.separator(factor=0.5)
        col.operator("rootmotion.disable_all", text="Disable All Root Motion", icon='PAUSE')


classes = (
    ROOTMOTION_OT_enable_all,
    ROOTMOTION_OT_disable_all,
    ROOTMOTION_PT_panel,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
