class_name WallSwitch
extends ToggledPart

## A wall switch: it lights the lamps it lists, not a light of its own (a LightSwitch is the lamp).
## The switches of one apartment that share a [member circuit] are ONE part in the building's state
## (ToggledPart.state_key): a two-way pair, by the door and by the bed, each putting out what the other
## lit. Its rocker tips with the state, on every client alike.

## The circuit's name, shared by the switches that work the same lights: their key in the apartment's
## state. Empty: a circuit of its own, keyed by the switch's path like any part.
@export var circuit: String = ""
## The lights it switches, from the switch, the way a LightGroup switches its own (LightGroup.switch):
## a LedPanel, a LightGroup, a bare Light3D, or a node whose lamps are below it.
@export var lights: Array[NodePath] = []
## The rocker that tips with the state, about its X axis (none: nothing moves).
@export var rocker_path: NodePath = ^"Rocker"
## How far the rocker tips from the middle, top in when on (degrees).
@export_range(0.0, 30.0, 0.5) var rocker_tilt_deg: float = 8.0


func state_key() -> String:
	if circuit == "":
		return super()
	var room: Node = apartment()
	return "%s/%s" % [room.name, circuit] if room != null else circuit


func _show(on: bool, animate: bool) -> void:
	for path: NodePath in lights:
		var light: Node = get_node_or_null(path)
		if light != null:
			LightGroup.switch(light, on, animate)
	var rocker := get_node_or_null(rocker_path) as Node3D
	if rocker != null:
		rocker.rotation.x = deg_to_rad(-rocker_tilt_deg if on else rocker_tilt_deg)
