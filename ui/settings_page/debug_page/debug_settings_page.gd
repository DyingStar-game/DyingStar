extends Control

## Settings > Debug: the in-game debug readouts and overlays, apart from the general options.

const TOGGLES : Array[Dictionary] = [
	{"node": "ShowDebug", "getter": "is_show_debug", "setter": "set_show_debug"},
	{"node": "CargoDebug", "getter": "is_cargo_debug", "setter": "set_cargo_debug"},
	{"node": "CelestialGizmos", "getter": "is_celestial_gizmos", "setter": "set_celestial_gizmos"},
	{"node": "SurfaceDebug", "getter": "is_surface_debug", "setter": "set_surface_debug"},
	{"node": "MusicDebug", "getter": "is_music_debug", "setter": "set_music_debug"},
	{"node": "VehicleHud", "getter": "is_vehicle_hud", "setter": "set_vehicle_hud"},
	{"node": "MovementDebug", "getter": "is_movement_debug", "setter": "set_movement_debug"},
]

@onready var _rows : VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer


func _ready() -> void:
	SettingsToggles.wire(_rows, TOGGLES)
	# Last: this reparents each row, so it must come after the node paths above are resolved.
	SettingsRow.wrap_rows(_rows)
