@tool
extends EditorPlugin


const GizmoPlugin: Resource = preload("res://addons/vehicle_lift/vehicle_lift_gizmo.gd")
var gizmo_plugin: EditorNode3DGizmoPlugin = GizmoPlugin.new()


func _enable_plugin() -> void:
	# Add autoloads here.
	pass


func _disable_plugin() -> void:
	# Remove autoloads here.
	pass


func _enter_tree() -> void:
	add_node_3d_gizmo_plugin(gizmo_plugin)
	pass


func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(gizmo_plugin)
	pass
