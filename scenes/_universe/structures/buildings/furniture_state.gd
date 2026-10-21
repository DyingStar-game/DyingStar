class_name FurnitureState
extends RefCounted

## The furniture of a spawn building's apartments someone set -- doors and drawers open or shut, lamps
## lit or not -- as {"<apartment>/<part>": bool} (ToggledPart.state_key), and showing it on the parts:
## all of them at once the first time (arriving in the zone, a restart), then only those that change,
## moving. A part not listed was never touched (ToggledPart.show_unset), so a new building's is empty.
## Replicated and kept by Horizon as the building's `furniture` property (SpawnBuilding).

## The state as it stands.
var state: Dictionary = {}

## The parts have been shown once: from then on a change moves (a door swings), before it is set.
var _shown: bool = false
## Every ToggledPart of the apartments, gathered once they exist.
var _parts: Array[ToggledPart] = []


## [param state] with the part [param key] set [param on]: a new dictionary, the old one untouched (it
## is compared with the new one).
static func with_part(from: Dictionary, key: String, on: bool) -> Dictionary:
	var out: Dictionary = from.duplicate()
	out[key] = on
	return out


## Take [param new_state] and show it on the parts under [param rooms] (null: they do not exist yet,
## the state is kept and shown once they do).
func receive(new_state: Dictionary, rooms: Node) -> void:
	var before: Dictionary = state
	state = new_state
	_show(rooms, before)


## Show the state on the parts under [param rooms] if it never was (the apartments just came to exist);
## nothing once it was -- a change comes through receive.
func show_once(rooms: Node) -> void:
	if not _shown:
		_show(rooms, state)


## Set [param part] [param on] and show it. Returns the new state, to replicate.
func set_part(part: ToggledPart, on: bool, rooms: Node) -> Dictionary:
	receive(with_part(state, part.state_key(), on), rooms)
	return state


## Show the state on the parts under [param rooms]: all of them the first time, then those whose
## value changed since [param before].
func _show(rooms: Node, before: Dictionary) -> void:
	if rooms == null:
		return
	if _parts.is_empty():
		_gather(rooms)
	for part in _parts:
		var key := part.state_key()
		if not state.has(key):
			if not _shown:
				part.show_unset()
		elif not _shown or state[key] != before.get(key):
			part.show_state(bool(state[key]), _shown)
	_shown = true


## The parts under [param room] that open for an NPC living there (MovingPart.opens_for_npc).
static func npc_doors(room: Node) -> Array:
	return room.find_children("*", "Area3D", true, false).filter(
			func(n: Node) -> bool: return n is MovingPart and (n as MovingPart).opens_for_npc)


func _gather(node: Node) -> void:
	for child in node.get_children():
		if child is ToggledPart:
			_parts.append(child)
		_gather(child)
