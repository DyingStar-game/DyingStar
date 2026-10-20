class_name VehicleSuspensionShocks
extends VehicleNetPart

## The knocks the suspensions take, detected where the physics runs and heard by everyone around.
##
## Only the game server simulates the wheels, and the wheel heights it replicates travel at 1 Hz (zone 1
## of vehicle_def.json): far too slow for a client to see a bump in them. So the SERVER detects each
## shock from its own 60 Hz physics, and replicates it as an EVENT: one shot counter per wheel, with the
## strength of its last shot. A client that sees a counter move plays that wheel's sound.
##
## The physics, per wheel: a shock is the wheel driven UP towards the body, fast. Its strength is the
## PEAK speed of that compression stroke -- how hard the spring had to answer. The shot is fired at the
## peak (the first tick the stroke slows down), so a single bump is a single sound, however many ticks
## it lasts; the stroke must then calm down before the wheel can fire again.
##
## The counters have a channel of their own (zone 2), with the same radius as the vehicle itself: only
## a shock sends it, and a player coming into range is a fresh vehicle on their side, so the counters
## it receives first are taken as the starting point, never replayed as shocks.

const KEY := "suspension_shocks"
## A stroke ends (and the wheel can fire again) once its speed falls under this share of min_speed.
const REARM_SHARE: float = 0.5
## A wheel moving more than this (m) in one tick is a rebuild or a reset, not a ride: no shock from it.
const JUMP_M: float = 0.3

enum Stroke { IDLE, RISING, FIRED }

## Compression speed (m/s, wheel towards the body) a shock needs to be heard at all.
var min_speed: float = 0.8
## Compression speed (m/s) of a full-strength shock.
var full_speed: float = 3.0
## Shortest time (s) between two shots of the same wheel.
var cooldown_s: float = 0.25

# SERVER, per wheel: last height (m, vehicle frame), stroke state, peak speed, cooldown left.
var _last_h: PackedFloat32Array = PackedFloat32Array()
var _stroke: PackedInt32Array = PackedInt32Array()
var _peak: PackedFloat32Array = PackedFloat32Array()
var _cooldown: PackedFloat32Array = PackedFloat32Array()
var _fired_speed: PackedFloat32Array = PackedFloat32Array()
## Per wheel [shot count, strength of the last shot in %]: what goes on the wire. The server writes it;
## a client keeps what it last received, to tell a new shot from the same one sent again.
var _shots: Array = []
var _sent: Variant = null  # nothing sent yet: the first call sends the counters
var _received: bool = false
var _heard: Array[Vector2i] = []  # CLIENT: (wheel, strength %) of the shots received, not yet played


## SERVER, once per physics tick: feed each wheel's height in the vehicle frame ([param heights], m, a
## higher wheel = a more compressed suspension). Returns the shots fired this tick as (wheel, strength %).
func track(heights: PackedFloat32Array, delta: float) -> Array[Vector2i]:
	var fired: Array[Vector2i] = []
	if delta <= 0.0:
		return fired
	if heights.size() != _last_h.size():
		_reset(heights)
		return fired
	for w in heights.size():
		var moved: float = heights[w] - _last_h[w]
		_last_h[w] = heights[w]
		_cooldown[w] = maxf(_cooldown[w] - delta, 0.0)
		if absf(moved) > JUMP_M:
			_stroke[w] = Stroke.IDLE
			continue
		var speed: float = moved / delta
		match _stroke[w]:
			Stroke.IDLE:
				if speed >= min_speed:
					_stroke[w] = Stroke.RISING
					_peak[w] = speed
			Stroke.RISING:
				if speed >= _peak[w]:
					_peak[w] = speed
				else:
					_stroke[w] = Stroke.FIRED
					if _cooldown[w] <= 0.0:
						fired.append(Vector2i(w, _fire(w)))
			Stroke.FIRED:
				if speed < min_speed * REARM_SHARE:
					_stroke[w] = Stroke.IDLE
	return fired


## SERVER: the compression speed (m/s) of [param wheel]'s last shot, for the log.
func fired_speed(wheel: int) -> float:
	return _fired_speed[wheel] if wheel < _fired_speed.size() else 0.0


## How hard (0..1) a stroke peaking at [param peak] m/s hits: nothing at min_speed, full at full_speed.
## Static and pure: tested without a vehicle.
static func strength(peak: float, min_s: float, full_s: float) -> float:
	return clampf((peak - min_s) / maxf(full_s - min_s, 0.001), 0.0, 1.0)


## Which of [param count] samples, listed from the softest to the hardest, a shock of [param hit]
## (0..1) plays: one of the (at most three) nearest its strength, never [param last] when another
## fits, chosen by [param roll] (0..1). Static and pure: tested without a vehicle.
static func pick_sample(hit: float, count: int, last: int, roll: float) -> int:
	if count <= 1:
		return 0
	var center: int = roundi(clampf(hit, 0.0, 1.0) * float(count - 1))
	var options: Array[int] = []
	for i in range(maxi(center - 1, 0), mini(center + 1, count - 1) + 1):
		if i != last:
			options.append(i)
	if options.is_empty():
		return center
	return options[mini(floori(clampf(roll, 0.0, 1.0) * options.size()), options.size() - 1)]


## CLIENT: the shots received since the last call, as (wheel, strength %), to be played once.
func take_heard() -> Array[Vector2i]:
	var out: Array[Vector2i] = _heard
	_heard = []
	return out


func write_changes(data: Dictionary) -> void:
	if _shots.is_empty() or (_sent != null and _sent == _shots):
		return
	data[KEY] = _shots.duplicate(true)
	_sent = _shots.duplicate(true)


func forget_sent() -> void:
	_sent = null


## Both sides: a client hears the counters that moved; the server, rebuilt from the database at boot,
## carries on counting from the stored values (a counter that went BACK would be heard as a shot).
func read(data: Dictionary) -> void:
	if not data.has(KEY) or not (data[KEY] is Array):
		return
	var shots: Array = []
	for entry in data[KEY]:
		var pair: Array = entry if entry is Array and (entry as Array).size() >= 2 else [0, 0]
		# Ints come back as floats from the JSON (Godot writes them that way, Horizon keeps them).
		shots.append([int(pair[0]), int(pair[1])])
	if _received:
		for w in mini(shots.size(), _shots.size()):
			if shots[w][0] != _shots[w][0]:
				_heard.append(Vector2i(w, shots[w][1]))
	_received = true
	_shots = shots
	_sent = shots.duplicate(true)


func _fire(w: int) -> int:
	var pct: int = roundi(strength(_peak[w], min_speed, full_speed) * 100.0)
	_cooldown[w] = cooldown_s
	_fired_speed[w] = _peak[w]
	while _shots.size() <= w:
		_shots.append([0, 0])
	_shots[w] = [int(_shots[w][0]) + 1, pct]
	return pct


## A new set of wheels (first tick, or the vehicle rebuilt): start from these heights, no stroke.
func _reset(heights: PackedFloat32Array) -> void:
	var n: int = heights.size()
	_last_h = heights.duplicate()
	_stroke.resize(n)
	_stroke.fill(Stroke.IDLE)
	_peak.resize(n)
	_peak.fill(0.0)
	_cooldown.resize(n)
	_cooldown.fill(0.0)
	_fired_speed.resize(n)
	_fired_speed.fill(0.0)
	while _shots.size() < n:
		_shots.append([0, 0])
