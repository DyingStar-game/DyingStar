@tool
class_name PlayerSpawnPointsList
extends Node3D

const REQUIRED_CHILD_CLASS = preload("res://tools/spawn_points/player_spawn_point.gd")

func _ready() -> void:
	if Engine.is_editor_hint():
		_update_warnings()

func _notification(what: int) -> void:
	if what == NOTIFICATION_CHILD_ORDER_CHANGED:
		_update_warnings()

func _update_warnings() -> void:
	update_configuration_warnings()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []

	var has_required_child: bool = false

	for child in get_children():
		if child is REQUIRED_CHILD_CLASS:
			has_required_child = true
			break

	if not has_required_child:
		warnings.append("This node requires at least one PlayerSpawnPoint child to function correctly.")

	return warnings
