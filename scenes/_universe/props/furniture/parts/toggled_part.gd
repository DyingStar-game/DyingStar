class_name ToggledPart
extends FurnitureTarget

## A furniture part with two states, off (shut, unlit) and on (open, lit). Its building keeps the state
## (SpawnBuilding.furniture, under state_key()): replicated to everyone near and kept across restarts.
## A use flips it on the server; every client, and the server, then shows it with show_state.

## Prompt while off, as "[E] <label_off>" (a translation key): what the key will do, "Open door".
@export var label_off: String = ""
## Prompt while on (a translation key): "Close door".
@export var label_on: String = ""

## True while on (open, lit), as last shown.
var is_on: bool = false


func _ready() -> void:
	super()
	label = label_off


## Its key in the building's state: "<apartment>/<its path in it>" ("0-1-0/Wardrobe/.../DoorR"),
## unique however many doors the apartment has.
func state_key() -> String:
	var room: Node = apartment()
	return "%s/%s" % [room.name, room.get_path_to(self)] if room != null else str(name)


## Show the part [param on] or off, moving there over time when [param animate] (a live change), at
## once otherwise (arriving in the zone, a restart: the state as it is).
func show_state(on: bool, animate: bool) -> void:
	is_on = on
	label = label_on if on else label_off
	_show(on, animate)


## What on and off look like: overridden by each kind of part.
func _show(_on: bool, _animate: bool) -> void:
	pass


## SERVER: flip it, through the building that keeps the state.
func server_use(_player: Node) -> void:
	var home := building() as SpawnBuilding
	if home != null:
		home.server_toggle_part(self)
