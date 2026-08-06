class_name VehicleDebugHud
extends CanvasLayer

## Vehicle dashboard overlay: speed (km/h), motor RPM, transmission, powertrain, weight /
## payload. Used both as the bench dev overlay (spawned when debug_hud is on) and as the
## in-game driver HUD (shown by Vehicle.set_driver_hud on enter). The shortcut hints adapt to
## the mode: bench exposes the debug keys (T spawn rock, N cycle traction), in-game only the
## keys the networked control path handles. The real in-cab dashboard (GDD) comes later.

var _vehicle: Vehicle = null
var _label: Label = null

func _ready() -> void:
	_vehicle = get_parent() as Vehicle
	_label = Label.new()
	_label.position = Vector2(24.0, 24.0)
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)

func _process(_delta: float) -> void:
	if _vehicle == null:
		return
	var speed: float = _vehicle.get_display_speed_kmh()
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
	# In-game (networked replica) the bench debug keys are off, so only advertise what the
	# player -> server control path handles. An empty uuid means the local bench.
	var in_game: bool = _vehicle.uuid != ""
	var trans_suffix := "" if in_game else "   (N)"
	var keys := (
		"[I] engine on/off (stopped)   [Y] exit   [Space] brake   [Hold Space <3km/h] handbrake\n"
		+ "[H] horn   [Alt+H] special horn   [L] lights   [R] flip" if in_game
		else "[I] engine on/off (stopped)   [T] rock   [N] drive mode   [Space] brake\n"
		+ "[Hold Space <3km/h] handbrake   [H] horn   [Alt+H] special horn   [R] flip")
	_label.text = (
		"Speed: %3.0f km/h%s%s\nEngine: %5.0f rpm\n%sTransmission: %s%s\nPowertrain: %s\n"
		+ "Total weight: %.0f kg\nLoad: %.0f / %.0f kg%s\n%s") % [
		speed, handbrake, ignition, rpm, _vehicle.get_gear_label(), _vehicle.get_drive_mode_name(),
		trans_suffix, _vehicle.get_propulsion_name(), total, cargo, _vehicle.max_payload, warn, keys]
