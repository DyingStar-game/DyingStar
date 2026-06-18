extends Control

## Wires the general options to SettingsManager (apply + persist). For now: the cargo-debug toggle
## (green envelope around items really locked into a vehicle bed), mirroring the graphics page style.

@onready var _cargo_debug: Button = $ScrollContainer/MarginContainer/VBoxContainer/CargoDebug/Button

func _ready() -> void:
	_cargo_debug.toggle_mode = true
	_cargo_debug.button_pressed = SettingsManager.is_cargo_debug()
	_cargo_debug.text = "On" if _cargo_debug.button_pressed else "Off"
	_cargo_debug.toggled.connect(_on_cargo_debug_toggled)

func _on_cargo_debug_toggled(on: bool) -> void:
	_cargo_debug.text = "On" if on else "Off"
	SettingsManager.set_cargo_debug(on)
