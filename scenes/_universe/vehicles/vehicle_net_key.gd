class_name VehicleNetKey
extends RefCounted
## The key a vehicle's seat or bay goes by in its replicated state: its node name in snake_case.
##
## Nodes follow Godot's naming (PascalCase: SeatDriver, SlotFL); the state that leaves the game —
## Horizon, the database, the admin API — reads snake_case (seat_driver, slot_fl). One function turns
## one into the other, used wherever a key is written AND wherever one is read back, so the two can
## never drift. A key read from an older save ("Slot_FL", "SeatDriver") normalizes to the same key.


## The key of [param node] (a VehicleSeat or a VehicleComponentSlot).
static func of(node: Node) -> String:
	return normalize(str(node.name))


## [param key] as the state spells it, whatever spelling it came in (a node name, an old save).
static func normalize(key: String) -> String:
	return key.to_snake_case()
