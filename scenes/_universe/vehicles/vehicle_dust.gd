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

## Most puffs per second a driven wheel throws, at full rate.
const PUFFS_PER_S: float = 14.0
## How much a full spin (wheel speed - road speed = dust_full_kmh) adds to the rate, on top of rolling.
const SLIP_GAIN: float = 1.5
## Share of the road speed the tyre throws the dust back at (m/s per m/s).
const THROW_BACK: float = 0.12
## Upward kick (m/s) of the dust off the tyre.
const THROW_UP: float = 0.9

var _vehicle: Vehicle = null
var _emitter: DustEmitter = null
var _accum: float = 0.0
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
	var intensity: float = rate(_vehicle.get_display_speed_kmh(), _vehicle.get_wheel_kmh(),
			dust.amount(family), _vehicle.dust_full_kmh)
	if intensity <= 0.0:
		_accum = 0.0
		return
	_accum += intensity * PUFFS_PER_S * delta
	if _accum < 1.0:
		return
	_accum = minf(_accum - 1.0, 1.0)  # never a burst to catch up after a hitch
	if _emitter == null:
		_emitter = DustEmitter.new(_vehicle, dust, 160, 2.6)
	var up: Vector3 = _vehicle.global_basis.y.normalized()
	var parent := _vehicle.get_parent() as Node3D
	var travel: Vector3 = (parent.global_basis * moved) if parent != null else moved
	var speed_ms: float = absf(_vehicle.get_display_speed_kmh()) / 3.6
	var back: Vector3 = -travel.normalized() * speed_ms * THROW_BACK if travel.length() > 0.0001 else Vector3.ZERO
	for contact: Vector3 in _vehicle.dust_contacts():
		_emitter.puff(contact, family, minf(intensity, 1.5), back + up * THROW_UP, 2, 0.25, 0.7)


## Drop the cloud now (the vehicle is leaving the tree).
func release() -> void:
	if _emitter != null:
		_emitter.release()
	_emitter = null
	_has_last = false
