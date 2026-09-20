@tool
extends AnimatableBody3D


@export var _platform_interface: CanvasLayer


func _ready() -> void:
	if Engine.is_editor_hint():
		var railing: Node3D = get_node_or_null("Platform/Railing")
		var railing_json_path: StringName = &"res://addons/vehicle_lift/platform/railing_datas.json"
		
		if railing:
			VehicleLift.generate_railings(railing, railing_json_path)


func _process(delta: float) -> void:
	pass


func update_interface_lift_progress(progress: float, eta: int, status: String) -> void:
	if _platform_interface:
		_platform_interface.display_progress(progress, eta, status)
