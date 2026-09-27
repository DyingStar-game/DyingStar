class_name VehicleSteering
extends RefCounted
## How the front wheels answer the pilot's steer axis. Pure maths, no scene: the vehicle copies its
## inspector tuning in (see Vehicle._sync_steering) and asks for the next angle each physics tick.
##
## The keys are a RATE, not a position. Holding a direction turns the wheels a little further every
## tick; letting go leaves them where they are — the pilot builds a turn up in taps, the way one
## feeds a real steering wheel through the hands. The previous model aimed the wheels at
## `axis * lock`, so a keyboard (whose axis is -1, 0 or 1) could only ask for full lock or straight
## ahead, and every release threw the truck back to centre.
##
## Rolling, a real wheel still drifts back toward straight on its own (caster): self_center_speed,
## scaled by how fast we roll, so a parked truck keeps its angle and a fast one straightens up.

## Maximum front-wheel angle, in degrees.
var max_deg: float = 30.0
## Above this forward speed (km/h) the lock has shrunk to min_ratio of max_deg. 0 disables it.
var falloff_kmh: float = 80.0
## Fraction of max_deg still available at/above falloff_kmh.
var min_ratio: float = 0.35
## How fast a held key turns the wheels further, in rad/s.
var turn_speed: float = 1.6
## How fast a held key turns the wheels back when it points AGAINST the current angle, in rad/s.
var return_speed: float = 3.0
## Hands-off drift back to centre at self_center_ref_kmh and above, in rad/s. 0 = the wheels never
## move on their own.
var self_center_speed: float = 0.3
## Speed at which the hands-off drift reaches self_center_speed; it scales linearly below it.
var self_center_ref_kmh: float = 50.0

## Below this, an axis value counts as "no key held".
const DEAD_ZONE := 0.01


## The largest angle the wheels may take at this forward speed, in radians: agile slow, stable fast.
func lock_rad(forward_kmh: float) -> float:
	var deg: float = max_deg
	if falloff_kmh > 0.0:
		var t: float = clampf(absf(forward_kmh) / falloff_kmh, 0.0, 1.0)
		deg = lerpf(max_deg, max_deg * min_ratio, t)
	return deg_to_rad(deg)


## The wheel angle after `delta` seconds, from `current` (radians), the pilot's steer axis `turn`
## in [-1, 1] and the signed forward speed. The result always lies inside the speed lock, so an
## angle held from a slow corner is brought back in as the truck picks up speed.
func step(current: float, turn: float, forward_kmh: float, delta: float) -> float:
	var next: float = current
	if absf(turn) > DEAD_ZONE:
		# Pointing back toward centre winds the wheels in faster than turning them out.
		var opposing: bool = current != 0.0 and signf(turn) != signf(current)
		var rate: float = return_speed if opposing else turn_speed
		next = current + turn * rate * delta
	elif self_center_speed > 0.0 and self_center_ref_kmh > 0.0:
		var roll: float = clampf(absf(forward_kmh) / self_center_ref_kmh, 0.0, 1.0)
		next = move_toward(current, 0.0, self_center_speed * roll * delta)
	var lock: float = lock_rad(forward_kmh)
	return clampf(next, -lock, lock)
