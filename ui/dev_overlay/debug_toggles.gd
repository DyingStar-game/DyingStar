class_name DebugToggles
extends Node
## The debug switches as the panel must see them: the value CARRIED by each change, not the one
## re-read from the settings. The F8 bug-report capture previews show_debug for one frame without
## saving it; a panel re-reading the setting would ignore it and miss the capture.

signal changed

## Switch key (DebugSettings.DEFAULTS) -> the value last announced.
var _on : Dictionary = {}


func _ready() -> void:
	for key: StringName in DebugSettings.DEFAULTS:
		_on[key] = SettingsManager.debug.is_on(key)
	SettingsManager.debug.changed.connect(_on_switch)


func is_on(key: StringName) -> bool:
	return bool(_on.get(key, false))


func _on_switch(key: StringName, on: bool) -> void:
	_on[key] = on
	changed.emit()
