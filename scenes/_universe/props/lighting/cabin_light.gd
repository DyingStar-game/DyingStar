class_name CabinLight
extends Node3D

## A cabin's ceiling light (shower, toilet) that follows its door: the door opens, and a moment later the
## tube strikes like a neon (NeonIgnition); the door shuts, and it goes out once the leaf is home --
## unless someone shut themselves in: then it stays on until the cabin is empty.
##
## It follows the door's replicated state (ToggledPart.state_shown): nothing of its own travels. On
## arrival a cabin found open, or shut on someone, is lit at once; otherwise dark. Visual only: nothing
## on the server. Its Light3D children are the light; the glowing face is the emission_on of
## [member glow_path].

## The door it follows (a ToggledPart: a MovingPart).
@export var door_path: NodePath
## The mesh whose emission_on glows with the light (the cabin's ceiling).
@export var glow_path: NodePath
## Seconds between the door opening and the tube striking.
@export_range(0.0, 3.0, 0.05) var strike_delay_s: float = 0.4
## The inside of the cabin, in its frame (the parent's): a player standing in it keeps the light on.
@export var inside: AABB = AABB(Vector3(-0.75, 0.0, -0.85), Vector3(1.5, 2.5, 1.7))
## Seconds between two looks for someone inside, while the door is shut on them.
@export_range(0.2, 10.0, 0.1) var presence_check_s: float = 1.0

## The door's last change: a timer started for an older one does nothing.
var _change: int = 0
var _ignition: Tween
var _door: ToggledPart


func _ready() -> void:
	_show(false)
	if GameOrchestrator.is_server():
		return
	_door = get_node_or_null(door_path) as ToggledPart
	if _door != null:
		_door.state_shown.connect(_on_door)


func _on_door(open: bool, animate: bool) -> void:
	_change += 1
	if not animate:
		_switch(open or occupied(), false)
		return
	var shut_s: float = (_door as MovingPart).duration_s if _door is MovingPart else 0.0
	_after(strike_delay_s if open else shut_s, _change, open)


## In [param seconds], unless the door moved meanwhile: light it ([param open]), or put it out if
## nobody is inside -- else look again a while later.
func _after(seconds: float, change: int, open: bool) -> void:
	get_tree().create_timer(seconds).timeout.connect(func() -> void:
		if change != _change or not is_inside_tree():
			return
		if open:
			_switch(true, true)
		elif occupied():
			_after(presence_check_s, change, false)
		else:
			_switch(false, false))


## True while a player stands inside the cabin.
func occupied() -> bool:
	var room := get_parent_node_3d()
	if room == null:
		return false
	var to_room: Transform3D = room.global_transform.affine_inverse()
	for body in get_tree().get_nodes_in_group(&"player"):
		if body is Node3D and inside.has_point(to_room * (body as Node3D).global_position + Vector3.UP * 0.1):
			return true
	return false


## Light it or put it out; coming on live, the tube strikes first.
func _switch(on: bool, animate: bool) -> void:
	if _ignition != null:
		_ignition.kill()
		_ignition = null
	if on and animate and is_inside_tree():
		_ignition = NeonIgnition.strike(self, _show)
	else:
		_show(on)


func _show(on: bool) -> void:
	for child in get_children():
		if child is Light3D:
			(child as Light3D).visible = on
	var glow := get_node_or_null(glow_path) as GeometryInstance3D
	if glow != null:
		glow.set_instance_shader_parameter(&"emission_on", on)
