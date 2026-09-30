class_name DebugToggles
extends Node
## The debug switches as the panel must see them: the value CARRIED by each settings signal, not the
## one re-read from SettingsManager. The F8 bug-report capture emits show_debug_changed(true) for one
## frame without saving it; a panel re-reading the setting would ignore it and miss the capture.

signal changed

var show_debug : bool = false
var surface : bool = false
var music : bool = false
var movement : bool = false
var vehicle_hud : bool = false


func _ready() -> void:
	show_debug = SettingsManager.is_show_debug()
	surface = SettingsManager.is_surface_debug()
	music = SettingsManager.is_music_debug()
	movement = SettingsManager.is_movement_debug()
	vehicle_hud = SettingsManager.is_vehicle_hud()
	SettingsManager.show_debug_changed.connect(_on_show_debug)
	SettingsManager.surface_debug_changed.connect(_on_surface)
	SettingsManager.music_debug_changed.connect(_on_music)
	SettingsManager.movement_debug_changed.connect(_on_movement)
	SettingsManager.vehicle_hud_changed.connect(_on_vehicle_hud)


func _on_show_debug(on: bool) -> void:
	show_debug = on
	changed.emit()


func _on_surface(on: bool) -> void:
	surface = on
	changed.emit()


func _on_music(on: bool) -> void:
	music = on
	changed.emit()


func _on_movement(on: bool) -> void:
	movement = on
	changed.emit()


func _on_vehicle_hud(on: bool) -> void:
	vehicle_hud = on
	changed.emit()
