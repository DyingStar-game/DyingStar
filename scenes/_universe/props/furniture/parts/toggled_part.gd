class_name ToggledPart
extends FurnitureTarget

## A furniture part with two states, off (shut, unlit) and on (open, lit). Its building keeps the state
## (SpawnBuilding.furniture, under state_key()): replicated to everyone near and kept across restarts.
## A use asks for the other state than the one shown -- what its prompt says -- the server sets it, and
## every client, and the server, then show it with show_state.

## Prompt while off, as "[E] <label_off>" (a translation key): what the key will do, "Open door".
@export var label_off: String = ""
## Prompt while on (a translation key): "Close door".
@export var label_on: String = ""

## Shown on or off -- [param animate] true for a live change, false for the state found on arrival.
## What follows a part listens to it (a cabin's light follows its door: CabinLight).
signal state_shown(on: bool, animate: bool)

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
	_display(on)
	_show(on, animate)
	state_shown.emit(on, animate)


## Shown [param on] or off: the state the prompt answers to ("[E] Close door" while open).
func _display(on: bool) -> void:
	is_on = on
	label = label_on if on else label_off


## Nobody set it yet: shut, unlit. A part with a mind of its own (a lamp lit by the night) says so.
func show_unset() -> void:
	show_state(false, false)


## What on and off look like: overridden by each kind of part.
func _show(_on: bool, _animate: bool) -> void:
	pass


func _use_data() -> Dictionary:
	return {"on": not is_on}


## SERVER: set it as asked, through the building that keeps the state.
func server_use(_player: Node, data: Dictionary) -> void:
	var home := building() as SpawnBuilding
	if home != null:
		home.server_set_part(self, bool(data.get("on", not is_on)))
