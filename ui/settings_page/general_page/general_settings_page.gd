extends Control

## Wires the general options to SettingsManager (apply + persist): the display language first, then
## the in-game debug toggles.

## One row per toggle: the node under the VBox, and the SettingsManager pair behind it. Declaring
## them beats six copies of the same four lines — adding a toggle becomes one entry, and the On/Off
## wording lives in a single place instead of twelve.
const TOGGLES : Array[Dictionary] = [
	{"node": "ShowDebug", "getter": "is_show_debug", "setter": "set_show_debug"},
	{"node": "CargoDebug", "getter": "is_cargo_debug", "setter": "set_cargo_debug"},
	{"node": "CelestialGizmos", "getter": "is_celestial_gizmos", "setter": "set_celestial_gizmos"},
	{"node": "SurfaceDebug", "getter": "is_surface_debug", "setter": "set_surface_debug"},
	{"node": "VehicleHud", "getter": "is_vehicle_hud", "setter": "set_vehicle_hud"},
	{"node": "MovementDebug", "getter": "is_movement_debug", "setter": "set_movement_debug"},
]

@onready var _rows : VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer
@onready var _language : OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/Language/OptionButton

func _ready() -> void:
	_fill_language()
	_language.item_selected.connect(_on_language_selected)
	# The picker is filled from code, so it does NOT re-translate itself the way a Control whose
	# text is set in the scene does. Rebuild it when the language changes under us.
	SettingsManager.language.changed.connect(_on_language_changed)
	for toggle in TOGGLES:
		_wire_toggle(toggle)
	# Last: this reparents each row, so it must come after the node paths above are resolved.
	SettingsRow.wrap_rows(_rows)

## Fill the picker: "Automatic" first, then every shipped language in its own words. The language
## CODE rides as item metadata instead of being read back from the visible text, which is a display
## string and would tie the stored value to its own wording.
func _fill_language() -> void:
	_language.clear()
	_language.add_item(tr("%%MENU_LANGUAGE_AUTO"))
	_language.set_item_metadata(0, LanguageSettings.AUTO)
	for code in LanguageSettings.LANGUAGES:
		_language.add_item(str(LanguageSettings.LANGUAGES[code]))
		_language.set_item_metadata(_language.item_count - 1, code)
	var current : String = SettingsManager.language.choice()
	for i in _language.item_count:
		if _language.get_item_metadata(i) == current:
			_language.select(i)
			return
	_language.select(0)

func _on_language_selected(index: int) -> void:
	SettingsManager.language.select(str(_language.get_item_metadata(index)))

## Rebuild so the "Automatic" entry follows the new language. select() emits nothing, so refilling
## from inside the change we just caused cannot loop.
func _on_language_changed(_language_code: String) -> void:
	_fill_language()

## Bind one toggle to its setting: current value in, new value out, label kept in step.
func _wire_toggle(toggle: Dictionary) -> void:
	var button : Button = _rows.get_node_or_null(str(toggle["node"]) + "/Button")
	# A typo in the table would otherwise leave a dead button that silently reports "off" forever.
	if button == null:
		push_error("General settings: no toggle button named %s" % toggle["node"])
		return
	button.toggle_mode = true
	button.button_pressed = bool(SettingsManager.call(toggle["getter"]))
	button.text = _toggle_label(button.button_pressed)
	button.toggled.connect(func(on: bool) -> void:
		button.text = _toggle_label(on)
		SettingsManager.call(toggle["setter"], on))

func _toggle_label(on: bool) -> String:
	return SettingsText.on_off(on)
