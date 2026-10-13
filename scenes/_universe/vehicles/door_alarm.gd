@tool
class_name DoorAlarm
extends RefCounted
## The open-door warning of a vehicle's dashboard: ONE beat for the door light's blink and for its beep,
## so the two never drift apart. A door open: a slow beat. Once the speed nears the one at which the
## wind shuts it (WARN_SHARE of it): faster and faster, up to FASTEST_S as it reaches it. Doors shut:
## silent, light off. Pure: the dashboard steps it each frame and plays the beep it asks for.

## The beat quickens past this share of the speed at which the wind shuts an open door.
const WARN_SHARE: float = 0.8
## Period of the beat (s): a door merely open, then from the warning speed down to the shutting speed.
const SLOW_S: float = 1.0
const FAST_S: float = 0.5
const FASTEST_S: float = 0.12

## Where in the current beat we are, 0..1: lit on its first half, the beep at its start.
var _phase: float = 0.0
var _on: bool = false


## true once [param speed_kmh] nears [param shut_kmh], the speed at which the wind shuts the open door
## (INF: a hatch the wind never shuts).
static func urgent(speed_kmh: float, shut_kmh: float) -> bool:
	return is_finite(shut_kmh) and absf(speed_kmh) >= shut_kmh * WARN_SHARE


## The beat's period (s) for the doors' state; 0 when every door is shut.
static func period(any_open: bool, speed_kmh: float, shut_kmh: float) -> float:
	if not any_open:
		return 0.0
	if not urgent(speed_kmh, shut_kmh):
		return SLOW_S
	var closing: float = inverse_lerp(shut_kmh * WARN_SHARE, shut_kmh, absf(speed_kmh))
	return lerpf(FAST_S, FASTEST_S, clampf(closing, 0.0, 1.0))


## Advance by [param delta_s] at [param period_s] (period()). true when a beep is due: at once when a
## door opens, then at the start of every beat.
func step(delta_s: float, period_s: float) -> bool:
	if period_s <= 0.0:
		_on = false
		_phase = 0.0
		return false
	if not _on:
		_on = true
		_phase = 0.0
		return true
	_phase += delta_s / period_s
	if _phase < 1.0:
		return false
	_phase = fmod(_phase, 1.0)
	return true


## Is the door light lit at this point of the beat (its first half)?
func lit() -> bool:
	return _on and _phase < 0.5
