extends Control

## Settings > Debug: the in-game debug readouts and overlays, apart from the general options.

## Row node -> its switch in DebugSettings.
const SWITCHES : Dictionary = {
	"ShowDebug": &"show_debug",
	"CargoDebug": &"cargo_debug",
	"CelestialGizmos": &"celestial_gizmos",
	"SurfaceDebug": &"surface_debug",
	"MusicDebug": &"music_debug",
	"StarMapDebug": &"star_map_debug",
	"VehicleHud": &"vehicle_hud",
	"MovementDebug": &"movement_debug",
}

@onready var _rows : VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer


func _ready() -> void:
	SettingsToggles.wire(_rows, SettingsToggles.switches(SWITCHES, "debug"))
	# Last: this reparents each row, so it must come after the node paths above are resolved.
	SettingsRow.wrap_rows(_rows)
