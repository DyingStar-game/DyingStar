class_name VehicleSpeedLimiter
extends VehicleNetPart
## A speed limiter, the kind a delivery van has: the pilot picks a speed, and past it the engine
## stops pushing however hard the pedal is held. It never adds a brake — downhill the truck may run
## over the limit, and slowing down is still the driver's job.
##
## Over the limit it does what a real one does, though: it closes the throttle, and a closed throttle
## holds the engine back (see overspeed). That is not a nicety. The game models no drag at all — no
## air, and no rolling resistance while the pedal is down — so an engine that merely stops pushing
## leaves a truck already above the limit rolling at that speed for ever: switching the limiter on at
## 50 km/h with a 30 limit did nothing visible.
##
## The chosen speed is kept when the limiter is off, so the dashboard can always show it and T turns
## the same limit back on. Server-authoritative: the pilot only asks (toggle, one step up or down).

const KEY_ON := "limiter_on"
const KEY_KMH := "limiter_kmh"
## How far over the limit before the throttle counts as closed. Right at the limit the engine simply
## stops pushing and, with nothing slowing the truck, it holds that speed; the margin keeps the two
## from taking turns every tick.
const OVERSPEED_MARGIN_KMH := 1.0

## Size of one step of the selector, in km/h.
var step_kmh: int = 5
## Lowest and highest selectable limit, in km/h.
var min_kmh: int = 5
var max_kmh: int = 130
## Below the limit by this much the engine already starts easing off, so the truck settles on it
## instead of banging against it.
var taper_kmh: float = 3.0

var enabled: bool = false
var cap_kmh: int = 30

var _sent_on: Variant = null  # nothing sent yet: the first call sends both keys
var _sent_kmh: int = -1


func toggle() -> void:
	enabled = not enabled


## One step up (dir > 0) or down (dir < 0), kept inside [min_kmh, max_kmh].
func step(dir: int) -> void:
	cap_kmh = clampi(cap_kmh + signi(dir) * step_kmh, min_kmh, max_kmh)


## What share of the engine force to keep, in [0, 1]. Full force when off, when the pilot is not
## pushing, or when the push opposes the motion (that is braking into a reverse, not speeding up).
func force_factor(throttle: float, forward_kmh: float) -> float:
	if not enabled or absf(throttle) < 0.01:
		return 1.0
	if absf(forward_kmh) > 0.5 and signf(throttle) != signf(forward_kmh):
		return 1.0
	if taper_kmh <= 0.0:
		return 1.0 if absf(forward_kmh) < float(cap_kmh) else 0.0
	return clampf((float(cap_kmh) - absf(forward_kmh)) / taper_kmh, 0.0, 1.0)


## True when the pilot pushes but the truck runs over the limit: the vehicle then treats the pedal as
## released, and its usual engine braking brings the speed back down.
func overspeed(throttle: float, forward_kmh: float) -> bool:
	if not enabled or absf(throttle) < 0.01:
		return false
	if signf(throttle) != signf(forward_kmh):
		return false
	return is_over(forward_kmh)


## True when the limiter is on and [param speed_kmh] (either sign) is over the limit by more than the
## margin: the engine is holding the truck back. The server brakes on it; the dashboard shows it red.
func is_over(speed_kmh: float) -> bool:
	return enabled and absf(speed_kmh) > float(cap_kmh) + OVERSPEED_MARGIN_KMH


func write_changes(data: Dictionary) -> void:
	if _sent_on == null or enabled != _sent_on:
		data[KEY_ON] = enabled
		_sent_on = enabled
	if cap_kmh != _sent_kmh:
		data[KEY_KMH] = cap_kmh
		_sent_kmh = cap_kmh


func read(data: Dictionary) -> void:
	if data.has(KEY_ON):
		enabled = bool(data[KEY_ON])
		_sent_on = enabled
	if data.has(KEY_KMH):
		# Godot sends integers as floats, and Horizon hands them back that way.
		cap_kmh = clampi(int(round(float(data[KEY_KMH]))), min_kmh, max_kmh)
		_sent_kmh = cap_kmh
