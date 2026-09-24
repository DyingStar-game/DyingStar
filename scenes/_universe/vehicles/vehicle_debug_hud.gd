class_name VehicleDebugHud
extends CanvasLayer

## Vehicle dashboard overlay: speed (km/h), motor RPM, transmission, powertrain, weight /
## payload, and what is bolted into the bays. Shown to the driver by Vehicle.set_driver_hud on
## enter, and hidden entirely by the "Vehicle dashboard" setting in General. The real in-cab
## dashboard (GDD) comes later.
##
## It is also THE INSTRUMENT for the drive model: it prints what VehicleDriveSpec predicts next
## to what the truck actually does. A model you cannot compare against a measurement is a model
## you have to take on faith — and the one number nobody can reason their way to is whether
## Godot's engine_force is per wheel or for the whole vehicle. The "implied force" line answers
## that: drive flat out from a standstill and compare it to engine_power x driven wheels.

## Sliding window for the measured acceleration (s). The replicated speed only refreshes at
## 30 Hz while _process runs faster, so a frame-to-frame difference is mostly noise; we compare
## against a sample taken this long ago instead.
const ACC_WINDOW := 0.5
## Below this speed (km/h) the vehicle counts as standing still: the stopwatch arms and the peak
## acceleration of the previous run is cleared.
const STANDSTILL_KMH := 1.0
const SPRINT_TARGET_KMH := 100.0

var _vehicle: Vehicle = null
var _label: Label = null

# --- Measurement --------------------------------------------------------------------------
var _samples: Array[Vector2] = []  # (elapsed seconds, speed in m/s)
var _acc_measured: float = 0.0
var _acc_peak: float = 0.0
## 0-100 km/h stopwatch. -1 = not running; a positive result is kept on screen until the next run.
var _sprint_t0: float = -1.0
var _sprint_result: float = 0.0
var _clock: float = 0.0

func _ready() -> void:
	_vehicle = get_parent() as Vehicle
	_label = Label.new()
	_label.position = Vector2(24.0, 24.0)
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)

func _process(delta: float) -> void:
	if _vehicle == null:
		return
	var speed: float = _vehicle.get_display_speed_kmh()
	_measure(delta, absf(speed))
	var rpm: float = _vehicle.get_engine_rpm()
	var total: float = _vehicle.mass
	var cargo: float = _vehicle.get_cargo_mass()
	var overloaded: bool = _vehicle.is_overloaded()
	var warn := ""
	if _vehicle.is_immobilized():
		warn = "   ⛔ IMMOBILIZED"
	elif overloaded:
		warn = "   ⚠ OVERLOADED"
	var handbrake := "   🅿 HANDBRAKE" if _vehicle.is_handbraked() else ""
	# The engine must be started (I) before the truck drives at all — say so loudly when it is off.
	var ignition := "" if _vehicle.is_engine_on() else "   🔑 ENGINE OFF — press [I] to start"
	_label.add_theme_color_override("font_color", Color(1, 0.3, 0.2) if overloaded else Color(1, 1, 1))
	# One control path now: everything a driver can do travels player -> server, so there is one
	# list of keys to advertise. (The second list was the test bench's own debug keys.)
	var keys := (
		"[I] engine on/off (stopped)   [Y] exit   [Space] brake   [Hold Space <3km/h] handbrake\n"
		+ "[H] horn   [Alt+H] special horn   [L] lights   [R] flip")
	_label.text = (
		"Speed: %3.0f km/h%s%s\nEngine: %5.0f rpm\n%sTransmission: %s%s\nPowertrain: %s\n"
		+ "Total weight: %.0f kg\nLoad: %.0f / %.0f kg%s\n%s\n%s\n%s\n%s") % [
		speed, handbrake, ignition, rpm, _vehicle.get_gear_label(), _vehicle.get_drive_mode_name(),
		"", _vehicle.get_propulsion_name(), total, cargo, _vehicle.max_payload, warn,
		_bays_line(), _model_line(total), _measured_line(total), keys]

## The component bays this vehicle carries and what sits in each. Worth a line of its own: an empty
## bay is invisible with the hatch shut, and the bay names are the keys the network table uses.
func _bays_line() -> String:
	var all_bays: Array = _vehicle.bays.all()
	if all_bays.is_empty():
		return "── Bays: none"
	var parts: PackedStringArray = PackedStringArray()
	for b in all_bays:
		parts.append("%s %s" % [b.name, b.occupant_name()])
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
## positive climbing, negative descending. The pair is the whole point — a number for what the truck
## can do is only useful beside a number for what it is being asked to do.
##
## Measured along the vehicle's FORWARD axis, not from its overall tilt, because that is the
## component that fights the drive: the load to beat is m·g·sin(pitch). Traversing a slope sideways
## therefore reads near zero, which is correct — it costs no tractive force.
##
## Honest about its limits: this is the vehicle's attitude, so airborne or on its roof it still
## reports an angle. Nothing else would be truthful without a ground query we do not need here.
func _slope_now() -> String:
	var up: Vector3 = _local_up()
	if up == Vector3.ZERO:
		return "—"
	return "%+.1f°" % pitch_deg(-_vehicle.global_transform.basis.z, up)


## Signed slope (degrees) of [param forward] against the local vertical [param up]: the angle the
## drive has to fight. Static and node-free so the sign convention can be tested without a scene —
## a flipped sign here would read perfectly plausibly and be wrong on every hill.
static func pitch_deg(forward: Vector3, up: Vector3) -> float:
	if forward.length_squared() < 0.000001 or up.length_squared() < 0.000001:
		return 0.0
	return rad_to_deg(asin(clampf(forward.normalized().dot(up.normalized()), -1.0, 1.0)))


## The local vertical, derived from the PLANET the vehicle hangs under rather than from the physics
## engine. The HUD runs on the driver's client, where a vehicle replica has its physics off, so
## Vehicle._gravity_up is never refreshed there — and its Vector3.UP default is ~65° away from local
## up at this project's astronomic coordinates, which would make every reading wrong and plausible.
## Same idiom as the player's own up in player_client: centre of the body, towards us.
func _local_up() -> Vector3:
	var n: Node = _vehicle.get_parent()
	while n != null and not (n is Planet):
		n = n.get_parent()
	if n == null:
		return Vector3.ZERO
	return (n as Node3D).global_position.direction_to(_vehicle.global_position)

## Sample the speed and derive acceleration over a sliding window, plus the 0-100 stopwatch.
func _measure(delta: float, speed_kmh: float) -> void:
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
