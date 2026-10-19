class_name VehicleCruiseControl
extends VehicleNetPart
## A cruise control: the pilot sets it at the speed they are driving (Ctrl+T), and the vehicle keeps
## that speed with the pedal released -- the engine pushes as much as the hold needs, no more. The
## wheel moves the set speed one step up or down. It never brakes: downhill it only closes the
## throttle, and the engine braking of a closed throttle does the rest.
##
## Touching a pedal hands the speed back to the pilot: accelerating or braking switches it off, as do a
## reverse, the engine stopping or the pilot leaving the seat (playtest 2026-10-19). A pedal already held
## when it is switched on counts only once let go: Ctrl+T at speed, foot still down, does not undo itself.
##
## Exclusive with the speed limiter (VehicleSpeedLimiter): one sets the speed, the other caps it, and
## the two at once would leave the pilot wondering which one holds the truck. Engaging one switches the
## other off (PlayerServer). Server-authoritative: the pilot only asks.

const KEY_ON := "cruise_on"
const KEY_KMH := "cruise_kmh"

## Size of one step of the selector, in km/h.
var step_kmh: int = 5
## Lowest and highest set speed, in km/h.
var min_kmh: int = 5
var max_kmh: int = 130
## Throttle per km/h of shortfall: full throttle this many km/h below the set speed is 1 / gain. A
## proportional hold, as on a real cruise control: it settles a little under the set speed, by just
## what the air and the slope need.
var gain: float = 0.3

var enabled: bool = false
var set_kmh: int = 30

## The pedal has been let go since it was switched on: from then on, pressing it switches it off.
var _pedal_free: bool = false
var _sent_on: Variant = null  # nothing sent yet: the first call sends both keys
var _sent_kmh: int = -1


## Ctrl+T: switch on at [param forward_kmh] (signed: negative backing up; rounded to the km/h, kept
## under max_kmh), or off. Not under min_kmh, backing up or standing still included: a hold set there
## would drive a parked or reversing truck forward on its own, as no real cruise control does.
func toggle(forward_kmh: float) -> void:
	if enabled:
		cancel()
		return
	if forward_kmh < float(min_kmh):
		return
	set_kmh = clampi(roundi(forward_kmh), min_kmh, max_kmh)
	enabled = true
	_pedal_free = false


## One step up (dir > 0) or down (dir < 0), kept inside [min_kmh, max_kmh].
func step(dir: int) -> void:
	set_kmh = clampi(set_kmh + signi(dir) * step_kmh, min_kmh, max_kmh)


func cancel() -> void:
	enabled = false


## The throttle the hold asks for at [param forward_kmh], in [0, 1]: what makes up the shortfall,
## nothing at or over the set speed, nothing when off.
func throttle(forward_kmh: float) -> float:
	if not enabled:
		return 0.0
	return clampf((float(set_kmh) - forward_kmh) * gain, 0.0, 1.0)


## The throttle the drive applies, from the pilot's [param pedal] (forward +): the hold while the pedal
## is released. Pressed either way -- accelerating, braking, a reverse -- it switches the hold off and
## the pedal drives; the pedal still held from before the switch-on drives over the hold until let go.
func drive_throttle(pedal: float, forward_kmh: float) -> float:
	if not enabled:
		return pedal
	if absf(pedal) <= 0.05:
		_pedal_free = true
	elif pedal < 0.0 or _pedal_free:
		cancel()
		return pedal
	return maxf(pedal, throttle(forward_kmh))


func write_changes(data: Dictionary) -> void:
	if _sent_on == null or enabled != _sent_on:
		data[KEY_ON] = enabled
		_sent_on = enabled
	if set_kmh != _sent_kmh:
		data[KEY_KMH] = set_kmh
		_sent_kmh = set_kmh


func forget_sent() -> void:
	_sent_on = null
	_sent_kmh = -1


func read(data: Dictionary) -> void:
	if data.has(KEY_ON):
		enabled = bool(data[KEY_ON])
		_sent_on = enabled
	if data.has(KEY_KMH):
		# Godot sends integers as floats, and Horizon hands them back that way.
		set_kmh = clampi(int(round(float(data[KEY_KMH]))), min_kmh, max_kmh)
		_sent_kmh = set_kmh
