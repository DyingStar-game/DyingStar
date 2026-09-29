extends Control

## Wires the general options to SettingsManager (apply + persist): the display language, the size
## of the interface, and the two display switches. The debug toggles have their own page (Debug).

const TOGGLES : Array[Dictionary] = [
	{"node": "GraphicsOverlay", "owner": "render", "getter": "is_overlay_enabled", "setter": "set_overlay_enabled"},
	{"node": "MenuStage", "owner": "render", "getter": "is_menu_stage_enabled", "setter": "set_menu_stage_enabled"},
]

@onready var _rows : VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer
@onready var _language : OptionButton = $ScrollContainer/MarginContainer/VBoxContainer/Language/OptionButton
@onready var _ui_scale : HSlider = $ScrollContainer/MarginContainer/VBoxContainer/UiScale/HSlider
@onready var _ui_scale_value : Label = $ScrollContainer/MarginContainer/VBoxContainer/UiScale/Value

func _ready() -> void:
	_fill_language()
	_language.item_selected.connect(_on_language_selected)
	# The picker is filled from code, so it does NOT re-translate itself the way a Control whose
	# text is set in the scene does. Rebuild it when the language changes under us.
	SettingsManager.language.changed.connect(_on_language_changed)
	_wire_ui_scale()
	SettingsToggles.wire(_rows, TOGGLES)
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


## Interface size: shown as it moves, applied when the drag ends — the page would otherwise rescale
## under the pointer dragging the slider.
func _wire_ui_scale() -> void:
	var settings : UiScaleSettings = SettingsManager.ui_scale
	_ui_scale.min_value = UiScaleSettings.MIN
	_ui_scale.max_value = UiScaleSettings.MAX
	_ui_scale.step = UiScaleSettings.STEP
	_ui_scale.set_value_no_signal(settings.value())
	_ui_scale_value.text = _percent(settings.value())
	var dragging : Array = [false]
	_ui_scale.drag_started.connect(func() -> void: dragging[0] = true)
	_ui_scale.drag_ended.connect(func(_moved: bool) -> void:
		dragging[0] = false
		settings.set_value(_ui_scale.value))
	_ui_scale.value_changed.connect(func(v: float) -> void:
		_ui_scale_value.text = _percent(v)
		if not dragging[0]:
			settings.set_value(v))


static func _percent(scale: float) -> String:
	return "%d %%" % roundi(scale * 100.0)
