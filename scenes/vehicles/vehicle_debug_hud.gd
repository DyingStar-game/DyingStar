class_name VehicleDebugHud
extends CanvasLayer

## Bench-only debug HUD: shows the parent vehicle's speed (km/h), wheel RPM (tachometer
## proxy) and current drive mode. Spawned by Vehicle when debug_hud is on. This is
## a dev overlay — the real in-cab dashboard (GDD) comes later.

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
		warn = "   ⛔ IMMOBILISÉ"
	elif overloaded:
		warn = "   ⚠ SURCHARGE"
	_label.add_theme_color_override("font_color", Color(1, 0.3, 0.2) if overloaded else Color(1, 1, 1))
	_label.text = (
		"Vitesse : %3.0f km/h\nMoteur : %5.0f tr/min\n%sTransmission : %s   (N)\n"
		+ "Poids total : %.0f kg\nCharge : %.0f / %.0f kg%s\n[T] rocher   [R] redresser") % [
		speed, rpm, _vehicle.get_gear_label(), _vehicle.get_drive_mode_name(),
		total, cargo, _vehicle.max_payload, warn]
