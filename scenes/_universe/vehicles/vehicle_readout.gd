class_name VehicleReadout
extends RefCounted
## The driver's debug readout: speed, motor RPM, transmission, powertrain, weight / payload, and what
## is bolted into the bays. Shown in the debug panel (DevOverlay) while driving, when the "Vehicle
## dashboard" setting in General is on. (The in-cab screen is VehicleDashboard; this is the bench.)
##
## It is also THE INSTRUMENT for the drive model: it prints what VehicleDriveSpec predicts next to
## what the truck actually does. A model you cannot compare against a measurement is a model you
## have to take on faith — and the one number nobody can reason their way to is whether Godot's
## engine_force is per wheel or for the whole vehicle. The "implied force" line answers that: drive
## flat out from a standstill and compare it to engine_power x driven wheels.
##
## No node: tick() measures every frame (the acceleration window and the 0-100 stopwatch need it),
## lines() writes the text whenever the panel refreshes.

## Sliding window for the measured acceleration (s). The replicated speed only refreshes at 30 Hz
## while frames come faster, so a frame-to-frame difference is mostly noise; we compare against a
## sample taken this long ago instead.
const ACC_WINDOW := 0.5
## Below this speed (km/h) the vehicle counts as standing still: the stopwatch arms and the peak
## acceleration of the previous run is cleared.
const STANDSTILL_KMH := 1.0
const SPRINT_TARGET_KMH := 100.0

var _vehicle: Vehicle = null

# --- Measurement --------------------------------------------------------------------------
var _samples: Array[Vector2] = []  # (elapsed seconds, speed in m/s)
var _acc_measured: float = 0.0
var _acc_peak: float = 0.0
## 0-100 km/h stopwatch. -1 = not running; a positive result is kept on screen until the next run.
var _sprint_t0: float = -1.0
var _sprint_result: float = 0.0
var _clock: float = 0.0


## Measure `vehicle` for one frame; a different vehicle (or none) starts a fresh measurement.
func tick(vehicle: Vehicle, delta: float) -> void:
	if vehicle != _vehicle:
		_vehicle = vehicle
		_reset()
	if is_instance_valid(_vehicle):
		measure(delta, absf(_vehicle.get_display_speed_kmh()))


func lines() -> PackedStringArray:
	if not is_instance_valid(_vehicle):
		return ["--"]
	var speed: float = _vehicle.get_display_speed_kmh()
	var total: float = _vehicle.mass
	var cargo: float = _vehicle.get_cargo_mass()
	var warn := ""
	if _vehicle.is_immobilized():
		warn = "   [color=#%s]IMMOBILIZED[/color]" % SettingsStyle.ALERT_COLOR.to_html(false)
	elif _vehicle.is_overloaded():
		warn = "   [color=#%s]OVERLOADED[/color]" % SettingsStyle.ALERT_COLOR.to_html(false)
	var handbrake := "   (P) HANDBRAKE" if _vehicle.is_handbraked() else ""
	# The engine must be started (I) before the truck drives at all — say so loudly when it is off.
	var ignition := "" if _vehicle.is_engine_on() else "   ENGINE OFF"
	var out : PackedStringArray = [
		"Speed: %3.0f km/h%s%s" % [speed, handbrake, ignition],
		"Engine: %5.0f rpm" % _vehicle.get_engine_rpm(),
	]
	# A thermal truck's gear on its own line ("Gear: 2"); an electric one has none.
	var gear : String = _vehicle.get_gear_label().strip_edges()
	if gear != "":
		out.append(gear)
	out.append_array([
		"Transmission: %s" % _vehicle.get_drive_mode_name(),
		"Powertrain: %s" % _vehicle.get_propulsion_name(),
		"Total weight: %.0f kg" % total,
		"Load: %.0f / %.0f kg%s" % [cargo, _vehicle.max_payload, warn],
		_bays_line(), _model_line(total), _measured_line(total),
	])
	return out


## Sample the speed and derive acceleration over a sliding window, plus the 0-100 stopwatch.
func measure(delta: float, speed_kmh: float) -> void:
	_clock += delta
	var speed_ms: float = speed_kmh / 3.6
	_samples.append(Vector2(_clock, speed_ms))
	# Drop everything older than the window, but keep the one sample just beyond it: that is the
	# "before" end of the measurement.
	while _samples.size() > 2 and _samples[1].x < _clock - ACC_WINDOW:
		_samples.remove_at(0)
	var span: float = _clock - _samples[0].x
	if span > 0.05:
		_acc_measured = (speed_ms - _samples[0].y) / span
		_acc_peak = maxf(_acc_peak, _acc_measured)
	# Stopwatch: arm at a standstill, start on the first real movement, stop at the target.
	if speed_kmh < STANDSTILL_KMH:
		_sprint_t0 = _clock
		_acc_peak = 0.0
		_sprint_result = 0.0
	elif _sprint_t0 >= 0.0 and speed_kmh >= SPRINT_TARGET_KMH:
		_sprint_result = _clock - _sprint_t0
		_sprint_t0 = -1.0


func acceleration() -> float:
	return _acc_measured


func peak_acceleration() -> float:
	return _acc_peak


## The last 0-100 km/h time, 0 while none was completed.
func sprint_time() -> float:
	return _sprint_result


## Signed slope (degrees) of [param forward] against the local vertical [param up]: the angle the
## drive has to fight. Static and node-free so the sign convention can be tested without a scene —
## a flipped sign here would read perfectly plausibly and be wrong on every hill.
static func pitch_deg(forward: Vector3, up: Vector3) -> float:
	if forward.length_squared() < 0.000001 or up.length_squared() < 0.000001:
		return 0.0
	return rad_to_deg(asin(clampf(forward.normalized().dot(up.normalized()), -1.0, 1.0)))


func _reset() -> void:
	_samples.clear()
	_acc_measured = 0.0
	_acc_peak = 0.0
	_sprint_t0 = -1.0
	_sprint_result = 0.0
	_clock = 0.0


## The component bays this vehicle carries and what sits in each. Worth a line of its own: an empty
## bay is invisible with the hatch shut, and the bay names are the keys the network table uses.
func _bays_line() -> String:
	var all_bays: Array = _vehicle.bays.all()
	if all_bays.is_empty():
		return "── Bays: none"
	var parts: PackedStringArray = PackedStringArray()
	for b in all_bays:
		var charge: String = ""
		if is_instance_valid(b.occupant) and b.occupant is VehicleBattery:
			charge = " " + EnergyFormat.charge(b.occupant.charge_j, b.occupant.capacity_j())
		parts.append("%s %s%s" % [b.name, b.occupant_name(), charge])
	return "── Bays: " + " · ".join(parts)


## What the drive model PREDICTS for the engines currently fitted, at the current total mass.
func _model_line(total_mass: float) -> String:
	var spec: VehicleDriveSpec = _vehicle.bays.drive_spec()
	if not spec.is_valid():
		return "── Model: NO ENGINE — fit one in a hatch"
	return "── Model: %d motor(s) · %.0f N · Vmax %.1f km/h (%s) · a %.2f m/s² · slope %.1f°" % [
		spec.motor_count(), spec.tractive_force_n(), spec.v_max_ms(total_mass) * 3.6,
		spec.limiting_factor(total_mass), spec.max_acceleration(total_mass),
		rad_to_deg(spec.max_slope_rad(total_mass))]


## What the truck ACTUALLY does. "implied" is the force the measured peak acceleration accounts
## for (a x m): compare it against engine_power x driven wheels to settle how Godot spreads
## engine_force. Godot models no rolling or aerodynamic drag while accelerating, so mass alone
## converts the two.
func _measured_line(total_mass: float) -> String:
	var implied: float = _acc_peak * total_mass
	var sprint := "—"
	if _sprint_result > 0.0:
		sprint = "%.2f s" % _sprint_result
	elif _sprint_t0 >= 0.0:
		sprint = "%.2f s…" % (_clock - _sprint_t0)
	return "── Measured: a %.2f (peak %.2f) m/s² · implies %.0f N · 0-100: %s · slope %s" % [
		_acc_measured, _acc_peak, implied, sprint, _slope_now()]


## The slope the vehicle is ACTUALLY on, next to the slope the model says it can climb. Signed:
## positive climbing, negative descending. Measured along the vehicle's FORWARD axis, not from its
## overall tilt, because that is the component that fights the drive: the load to beat is
## m·g·sin(pitch). Traversing a slope sideways therefore reads near zero, which is correct.
## Honest about its limits: this is the vehicle's attitude, so airborne or on its roof it still
## reports an angle.
func _slope_now() -> String:
	var up: Vector3 = _local_up()
	if up == Vector3.ZERO:
		return "—"
	return "%+.1f°" % pitch_deg(-_vehicle.global_transform.basis.z, up)


## The local vertical, derived from the PLANET the vehicle hangs under rather than from the physics
## engine. The readout runs on the driver's client, where a vehicle replica has its physics off, so
## Vehicle._gravity_up is never refreshed there — and its Vector3.UP default is ~65° away from local
## up at this project's astronomic coordinates, which would make every reading wrong and plausible.
func _local_up() -> Vector3:
	var n: Node = _vehicle.get_parent()
	while n != null and not (n is Planet):
		n = n.get_parent()
	if n == null:
		return Vector3.ZERO
	return (n as Node3D).global_position.direction_to(_vehicle.global_position)
