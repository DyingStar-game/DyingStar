extends Control

## Wires the general options to SettingsManager (apply + persist). For now: the cargo-debug toggle
## (green envelope around items really locked into a vehicle bed), mirroring the graphics page style.

@onready var _show_debug: Button = $ScrollContainer/MarginContainer/VBoxContainer/ShowDebug/Button
@onready var _cargo_debug: Button = $ScrollContainer/MarginContainer/VBoxContainer/CargoDebug/Button
@onready var _celestial_gizmos: Button = $ScrollContainer/MarginContainer/VBoxContainer/CelestialGizmos/Button

func _ready() -> void:
	_show_debug.toggle_mode = true
	_show_debug.button_pressed = SettingsManager.is_show_debug()
	_show_debug.text = "On" if _show_debug.button_pressed else "Off"
	_show_debug.toggled.connect(_on_show_debug_toggled)

	_cargo_debug.toggle_mode = true
	_cargo_debug.button_pressed = SettingsManager.is_cargo_debug()
	_cargo_debug.text = "On" if _cargo_debug.button_pressed else "Off"
	_cargo_debug.toggled.connect(_on_cargo_debug_toggled)

	_celestial_gizmos.toggle_mode = true
	_celestial_gizmos.button_pressed = SettingsManager.is_celestial_gizmos()
	_celestial_gizmos.text = "On" if _celestial_gizmos.button_pressed else "Off"
	_celestial_gizmos.toggled.connect(_on_celestial_gizmos_toggled)

## Show/hide the in-game debug panels. Kept in sync with the toggle_debug key via SettingsManager.
func _on_show_debug_toggled(on: bool) -> void:
	_show_debug.text = "On" if on else "Off"
	SettingsManager.set_show_debug(on)

func _on_cargo_debug_toggled(on: bool) -> void:
	_cargo_debug.text = "On" if on else "Off"
	SettingsManager.set_cargo_debug(on)

## Show/hide the in-world star/planet/moon markers (orientation aid).
func _on_celestial_gizmos_toggled(on: bool) -> void:
	_celestial_gizmos.text = "On" if on else "Off"
	SettingsManager.set_celestial_gizmos(on)
