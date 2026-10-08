class_name VehicleDust
extends RefCounted

## The dust a vehicle's tyres throw up — client side, from the replicated motion (see DustEmitter).
##
## Kept out of vehicle.gd for the same reason as the odometer and the limiter: that file is at
## gdlint's public-method ceiling, and this is a job of its own.
##
## The physics, per driven wheel:
##   - a tyre lifts loose grains in proportion to how fast it sweeps the ground: the dust grows with
##     the SPEED, up to Vehicle.dust_full_kmh;
##   - a SPINNING tyre (wheel speed above the road speed) digs and throws far more than a rolling one;
##   - the GROUND decides how much there is to lift (SurfaceDust: sand a lot, rock little, metal none);
##   - the dust is thrown BACK from the contact patch, and left behind in the air: the trail.

## One puff per this many metres a driven wheel rolls: the trail is laid by DISTANCE, not by time. Timed
## puffs (14 a second at most, 4 on rock) left 4 m between them at 60 km/h, for clouds born 0.7 m wide —
## a string of separate blobs, "pot pot pot", an engine coughing (2026-10-06). Under the puff's size the
## clouds merge into one trail at any speed, and the dust per metre driven no longer depends on the speed.
const PUFF_SPACING_M: float = 0.8
## Puffs per second a wheel spinning in place throws (it rolls no distance, but it digs).
const SLIP_PUFFS_PER_S: float = 14.0
## How much a full spin (wheel speed - road speed = dust_full_kmh) adds to the stir, on top of rolling.
const SLIP_GAIN: float = 1.5
## Most puffs a wheel throws in one frame: after a hitch, a short trail rather than a pile-up.
const MAX_PUFFS_PER_FRAME: int = 6
## A move longer than this (m) in one frame is a teleport or a reparent, not a drive: no trail along it.
const TELEPORT_M: float = 30.0
## Share of the road speed the tyre throws the dust back at (m/s per m/s).
const THROW_BACK: float = 0.12
## Upward kick (m/s) of the dust off the tyre.
const THROW_UP: float = 0.9

var _vehicle: Vehicle = null
var _emitter: DustEmitter = null
var _accum: float = 0.0  # puffs owed to each driven wheel, fractional
var _last_pos: Vector3 = Vector3.ZERO
var _has_last: bool = false


func _init(vehicle: Vehicle) -> void:
	_vehicle = vehicle


## How hard (0..1+) a driven wheel stirs the ground: rolling plus spinning, times what the ground has
## to give. Static and pure: the rule is tested without a vehicle.
static func rate(speed_kmh: float, wheel_kmh: float, amount: float, full_kmh: float) -> float:
	var full: float = maxf(full_kmh, 0.1)
	var roll: float = clampf(absf(speed_kmh) / full, 0.0, 1.0)
	var slip: float = clampf((absf(wheel_kmh) - absf(speed_kmh)) / full, 0.0, 1.0)
	return clampf(amount, 0.0, 1.0) * (roll + SLIP_GAIN * slip)


## Once per frame, from the vehicle's client _process (after the wheels are posed).
func update(delta: float, family: StringName) -> void:
	var dust: SurfaceDust = _vehicle.dust
	if dust == null or not DustEmitter.enabled() or delta <= 0.0:
		return
	# Direction of travel from the replica's own motion, in its parent's frame (the planet turns: a
	# world-space delta would make a parked truck "drive"), turned back to world for the throw.
	var pos: Vector3 = _vehicle.position
	var moved: Vector3 = pos - _last_pos if _has_last else Vector3.ZERO
	_last_pos = pos
	_has_last = true
	# How hard the tyres stir, whatever the ground: the ground's own share is applied ONCE, by puff()
	# (counted twice, it squared: rock and corundum raised no visible dust). The speed is the one the
	# wheels are SHOWN rolling at: the replicated motion on a networked truck, and the only speed a menu
	# truck has (frozen and carried, its physics speed is zero; it does not spin, so no slip).
	var stir: float = rate(_vehicle.shown_speed_kmh, _vehicle.get_wheel_kmh(), 1.0, _vehicle.dust_full_kmh)
	var roll: float = rate(_vehicle.shown_speed_kmh, _vehicle.shown_speed_kmh, 1.0, _vehicle.dust_full_kmh)
	var distance: float = moved.length()
	if stir <= 0.0 or dust.amount(family) <= 0.0 or distance > TELEPORT_M:
		_accum = 0.0
		return
	_accum += puffs_owed(distance, (stir - roll) / SLIP_GAIN, delta)
	var count: int = mini(floori(_accum), MAX_PUFFS_PER_FRAME)
	if count <= 0:
		return
	_accum = minf(_accum - count, 1.0)
	if _emitter == null:
		_emitter = DustEmitter.new(_vehicle, dust, 512, 2.6)
	var up: Vector3 = _vehicle.global_basis.y.normalized()
	var parent := _vehicle.get_parent() as Node3D
	var travel: Vector3 = (parent.global_basis * moved) if parent != null else moved
	var speed_ms: float = absf(_vehicle.shown_speed_kmh) / 3.6
	var back: Vector3 = -travel.normalized() * speed_ms * THROW_BACK if travel.length() > 0.0001 else Vector3.ZERO
	for contact: Vector3 in _vehicle.dust_contacts():
		for i in count:
			# Spread along the stretch rolled since the last frame, so the trail has no gaps at speed.
			var along: float = 1.0 - (float(i) + 0.5) / float(count)
			_emitter.puff(contact - travel * along, family, minf(stir, 1.5), back + up * THROW_UP, 1, 0.25, 0.7)


## Puffs a driven wheel owes for a frame: one per PUFF_SPACING_M rolled ([param distance_m]), plus the
## dig of a wheel spinning faster than it rolls ([param slip], 0..1), in time. Static and pure: tested
## without a vehicle.
static func puffs_owed(distance_m: float, slip: float, delta: float) -> float:
	return maxf(distance_m, 0.0) / PUFF_SPACING_M + clampf(slip, 0.0, 1.0) * SLIP_PUFFS_PER_S * maxf(delta, 0.0)


## Drop the cloud now (the vehicle is leaving the tree).
func release() -> void:
	if _emitter != null:
		_emitter.release()
	_emitter = null
	_has_last = false
