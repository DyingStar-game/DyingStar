class_name HintSource
extends Node
## Play hints from a scene, with no code: drop this node anywhere — under a console, a vehicle, a
## machine — fill its rows in the Inspector, and its lines join the panel on the left of the screen
## (see PlayHints) while it is in the tree and active, and, if `near_m` is set, while the camera is
## close to its parent.
##
## Client only: nothing is offered on the dedicated server, which shows no hints.

## Name of these lines, unique per node: another HintSource with the same context on the same node
## replaces them. Empty = this node's name.
@export var context : StringName = &""
## The lines to show, in order. Each: the action(s), and a label key (empty = the controls page's).
@export var rows : Array[HintRow] = []
## Listed before the lines of a lower priority (on foot 0, EVA 5, at the wheel 10, carrying 20).
@export var priority : int = 30
## Whether the lines show at all. Switch it from code or an AnimationPlayer for a lever, a door…
@export var active : bool = true
## Show only while the camera is within this distance (m) of the parent node; 0 = wherever it is.
@export_range(0.0, 100.0, 0.5) var near_m : float = 0.0


func _enter_tree() -> void:
	if Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return
	var lines : Array = []
	for r: HintRow in rows:
		if r != null and not r.actions.is_empty():
			lines.append(r.to_row())
	PlayHints.provide(self, _context(), lines, _wanted, priority)


func _exit_tree() -> void:
	PlayHints.withdraw(self, _context())


func _context() -> StringName:
	return context if context != &"" else StringName(name)


func _wanted() -> bool:
	if not active or not is_inside_tree():
		return false
	if near_m <= 0.0:
		return true
	var anchor := get_parent() as Node3D
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	if anchor == null or camera == null:
		return false
	return camera.global_position.distance_squared_to(anchor.global_position) <= near_m * near_m
