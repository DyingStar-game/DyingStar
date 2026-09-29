class_name SettingsToggles
extends RefCounted
## On / Off lines bound to their setting, from a table — the General and Debug pages each declare
## theirs. One entry per line: "node" (the row under `rows`, whose Button it drives), "getter" and
## "setter" on SettingsManager, or on the SettingsManager member named by "owner" (e.g. "render").
## Adding a toggle is one entry, and the On / Off wording lives in one place.


static func wire(rows: Node, toggles: Array[Dictionary]) -> void:
	for toggle in toggles:
		_wire(rows, toggle)


## Current value in, new value out, label kept in step.
static func _wire(rows: Node, toggle: Dictionary) -> void:
	var button : Button = rows.get_node_or_null(str(toggle["node"]) + "/Button")
	# A typo in a table would otherwise leave a dead button that silently reports "off" forever.
	if button == null:
		push_error("Settings: no toggle button named %s" % toggle["node"])
		return
	var target : Object = SettingsManager.get(toggle["owner"]) if toggle.has("owner") else SettingsManager
	button.toggle_mode = true
	button.button_pressed = bool(target.call(toggle["getter"]))
	button.text = SettingsText.on_off(button.button_pressed)
	button.toggled.connect(func(on: bool) -> void:
		button.text = SettingsText.on_off(on)
		target.call(toggle["setter"], on))
