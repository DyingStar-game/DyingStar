class_name VehiclePowertrain
extends RefCounted

## Powertrain math for the Vehicle (SRP): turns throttle + forward speed into engine force,
## and (THERMAL) runs the automatic gearbox. Pure logic, no scene nodes — the Vehicle owns
## one, copies its inspector settings into it (sync) and feeds it the throttle / speed each
## physics frame. Splitting this out keeps vehicle.gd about the body, not the engine curves.

## ELECTRIC = single-speed, instant torque. THERMAL = gearbox with automatic shifting.
enum Type {ELECTRIC, THERMAL}

var type: Type = Type.ELECTRIC
var engine_power: float = 1200.0
var max_speed_kmh: float = 45.0
var reverse_max_kmh: float = 15.0

# Electric
var base_speed_kmh: float = 25.0
var motor_max_rpm: float = 9000.0

# Thermal gearbox
var gear_ratios: Array[float] = [2.5, 1.7, 1.25, 1.0, 0.8]
var shift_up_rpm: float = 3400.0
var shift_down_rpm: float = 1400.0
var reverse_ratio: float = 2.5
var idle_rpm: float = 800.0
var redline_rpm: float = 4000.0

## Gearbox state (THERMAL). Kept across frames; the Vehicle's sync never resets it.
var current_gear: int = 0

## Engine force for the given (already ramped) throttle and forward speed (km/h).
func force(throttle: float, forward_kmh: float) -> float:
	if type == Type.ELECTRIC:
		return _electric_force(throttle, forward_kmh)
	return _thermal_force(throttle, forward_kmh)

## Engine/motor RPM for the gauge (depends on the powertrain).
func engine_rpm(forward_kmh: float) -> float:
	if type == Type.ELECTRIC:
		return motor_max_rpm * clampf(absf(forward_kmh) / maxf(max_speed_kmh, 0.1), 0.0, 1.0)
	return _gearbox_rpm(forward_kmh, current_gear)

## HUD label: the current gear (THERMAL) or empty (ELECTRIC has no gears).
func gear_label() -> String:
	if type == Type.THERMAL:
		return "Gear: %d\n" % (current_gear + 1)
	return ""

## ELECTRIC powertrain: single-speed, full torque up to base_speed then taper (constant power).
func _electric_force(throttle: float, forward_kmh: float) -> float:
	if throttle > 0.001:
		var factor: float = 1.0
		if forward_kmh > base_speed_kmh:
			factor = clampf((max_speed_kmh - forward_kmh) / maxf(max_speed_kmh - base_speed_kmh, 0.1), 0.0, 1.0)
		return throttle * engine_power * factor
	if throttle < -0.001:
		var rev: float = clampf((reverse_max_kmh + forward_kmh) / maxf(reverse_max_kmh, 0.1), 0.0, 1.0)
		return throttle * engine_power * rev
	return 0.0

## THERMAL powertrain: automatic gearbox; low gears pull harder, taper near top speed.
func _thermal_force(throttle: float, forward_kmh: float) -> float:
	if throttle > 0.001:
		_update_gear(forward_kmh)
		var ratio: float = _gear_ratio(current_gear)
		var top_factor: float = 1.0
		if current_gear >= gear_ratios.size() - 1:
			top_factor = clampf((max_speed_kmh - forward_kmh) / maxf(max_speed_kmh * 0.1, 0.1), 0.0, 1.0)
		return throttle * engine_power * ratio * top_factor
	if throttle < -0.001:
		current_gear = 0
		var rev: float = clampf((reverse_max_kmh + forward_kmh) / maxf(reverse_max_kmh * 0.2, 0.1), 0.0, 1.0)
		return throttle * engine_power * reverse_ratio * rev
	return 0.0

func _gear_ratio(gear: int) -> float:
	if gear_ratios.is_empty():
		return 1.0
	return gear_ratios[clampi(gear, 0, gear_ratios.size() - 1)]

## Automatic shifting (THERMAL): up near the redline, down when the engine bogs down.
func _update_gear(forward_kmh: float) -> void:
	var rpm: float = _gearbox_rpm(forward_kmh, current_gear)
	if rpm > shift_up_rpm and current_gear < gear_ratios.size() - 1:
		current_gear += 1
	elif rpm < shift_down_rpm and current_gear > 0:
		current_gear -= 1

## Engine RPM for a given speed and gear (THERMAL): redline at max_speed in the top gear.
func _gearbox_rpm(forward_kmh: float, gear: int) -> float:
	if gear_ratios.is_empty():
		return idle_rpm
	var top: float = gear_ratios[gear_ratios.size() - 1]
	var rpm: float = redline_rpm * (absf(forward_kmh) / maxf(max_speed_kmh, 0.1)) * (_gear_ratio(gear) / top)
	return clampf(rpm, idle_rpm, redline_rpm)
