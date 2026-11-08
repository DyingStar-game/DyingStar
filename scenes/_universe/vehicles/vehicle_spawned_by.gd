class_name VehicleSpawnedBy
extends VehicleNetPart
## Who had the vehicle delivered: the player's name, set once at the spawn (ItemDispenser) and written on
## the registration plate above the serial (playtest 2026-11-08). It travels in the spawn data and lives
## in Horizon's static zone (vehicle_def.json), so a late joiner reads it with the vehicle.

const KEY := "spawned_by"

var name: String = ""

var _sent: String = ""


func write_changes(data: Dictionary) -> void:
	if name != _sent:
		data[KEY] = name
		_sent = name


func forget_sent() -> void:
	_sent = ""


func read(data: Dictionary) -> void:
	if data.has(KEY):
		name = str(data[KEY])
		_sent = name
