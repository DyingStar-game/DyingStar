class_name VehicleOdometer
extends VehicleNetPart
## How far this vehicle has driven, in its life — across sessions and server restarts, because the
## value is replicated (key "odometer_km") and Horizon's persistence stores what is replicated.
##
## Counted by the server from the vehicle's LOCAL position, the one relative to its parent: the
## planet it drives on moves and spins, and the local frame is the one in which "driving 1 m" means
## 1 m of ground. A step is skipped when the parent changes (a new frame, the two positions do not
## compare) or when it is too long to have been driven (a reset, a teleport, a restore).

const KEY := "odometer_km"
## Longer than any vehicle drives in one physics tick (50 m at 60 Hz is 10 800 km/h).
const MAX_STEP_M := 50.0
## Precision on the wire: 100 m. At 100 km/h that is one update every 3.6 s.
const WIRE_KM := 0.1

var _metres: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _last_parent: String = ""
var _has_last: bool = false
var _sent_km: float = -1.0


## Kilometres driven.
func km() -> float:
	return _metres / 1000.0


## Server, every physics tick: account for the move from the previous position.
func track(local_pos: Vector3, parent_id: String) -> void:
	if _has_last and parent_id == _last_parent:
		var step: float = local_pos.distance_to(_last_pos)
		if step <= MAX_STEP_M:
			_metres += step
	_last_pos = local_pos
	_last_parent = parent_id
	_has_last = true


func write_changes(data: Dictionary) -> void:
	var km_now: float = snappedf(km(), WIRE_KM)
	if km_now != _sent_km:
		data[KEY] = km_now
		_sent_km = km_now


func read(data: Dictionary) -> void:
	if data.has(KEY):
		_sent_km = float(data[KEY])
		_metres = _sent_km * 1000.0
