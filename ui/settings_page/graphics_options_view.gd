class_name GraphicsOptionsView
extends Node
## The rendering options as settings lines: built from GraphicsOptions, bound to SettingsManager.render.
##
## One view for two places — the Graphics page and the in-game overlay — so an option exists once
## on screen as it exists once in data. It writes nothing but through RenderSettings, and redraws
## everything from it on every `changed`: a preset picked in the overlay, an option greyed because
## FSR 2.2 was chosen, a language switch — all reach both places the same way.
##
## A Node (added under its page) rather than a RefCounted, so its signal connections die with the
## page: settings pages are freed and rebuilt on every tab switch.

## Dim a greyed line's caption as well as its control, so the whole line reads as unavailable.
const _DISABLED_ALPHA : float = 0.45

var _factory : SettingsRowFactory
## key -> {"option", "line", "label", "control", "value"}. "value" is the slider's number label, or null.
var _rows : Dictionary = {}
var _preset : OptionButton = null
## The preset's whole line, which carries its explanation on hover.
var _preset_line : HBoxContainer = null
var _recommended : Label = null
## Sliders being dragged: they commit on release (see _wire_slider).
var _dragging : Dictionary = {}


func _init(factory: SettingsRowFactory) -> void:
	_factory = factory


## Fill `container` with the preset line (when asked) and one heading + lines per section.
func build(container: Container, with_preset: bool = true) -> void:
	if with_preset:
		_build_preset(container)
	for section in GraphicsOptions.SECTIONS:
		container.add_child(_factory.header(section))
		for option in GraphicsOptions.in_section(section):
			_build_row(container, option)
	SettingsManager.render.changed.connect(_on_changed)
	# Texts built with tr() (the Recommended line) must follow a language switch.
	SettingsManager.language.changed.connect(_on_language_changed)
	_refresh()


func _build_preset(container: Container) -> void:
	var line : HBoxContainer = _factory.row("%%MENU_GFX_PRESET")
	_preset = _factory.option_button()
	for i in GraphicsOptions.PRESETS.size():
		_preset.add_item(GraphicsOptions.PRESET_LABELS[GraphicsOptions.PRESETS[i]], i)
	# Custom is where you LAND by changing an option, never something you pick.
	_preset.add_item(GraphicsOptions.PRESET_LABELS[GraphicsOptions.CUSTOM], GraphicsOptions.PRESETS.size())
	_preset.set_item_disabled(GraphicsOptions.PRESETS.size(), true)
	_preset.item_selected.connect(func(i: int) -> void:
		if i < GraphicsOptions.PRESETS.size():
			SettingsManager.render.apply_preset(GraphicsOptions.PRESETS[i]))
	line.add_child(_preset)
	container.add_child(line)
	_preset_line = line
	var hint : HBoxContainer = _factory.row("")
	_recommended = hint.get_child(0)
	var apply : Button = _factory.button("%%MENU_GFX_APPLY_RECOMMENDED")
	apply.pressed.connect(func() -> void:
		SettingsManager.render.apply_preset(SettingsManager.render.detected()))
	hint.add_child(apply)
	container.add_child(hint)


func _build_row(container: Container, option: Dictionary) -> void:
	var key : String = option["key"]
	var line : HBoxContainer = _factory.row(option["label"])
	var entry : Dictionary = {"option": option, "line": line, "label": line.get_child(0), "control": null,
		"value": null}
	match option["kind"]:
		GraphicsOptions.TOGGLE:
			var button : Button = _factory.toggle()
			button.toggled.connect(func(on: bool) -> void: SettingsManager.render.set_value(key, on))
			entry["control"] = button
		GraphicsOptions.CHOICE:
			var picker : OptionButton = _factory.option_button()
			for i in option["choices"].size():
				picker.add_item(option["choices"][i][1], i)
				picker.set_item_metadata(i, option["choices"][i][0])
			picker.item_selected.connect(func(i: int) -> void:
				SettingsManager.render.set_value(key, picker.get_item_metadata(i)))
			entry["control"] = picker
		GraphicsOptions.SLIDER:
			var bar : HSlider = _factory.slider(option["min"], option["max"], option["step"])
			var number : Label = _factory.value_label()
			_wire_slider(bar, number, option)
			entry["control"] = bar
			entry["value"] = number
	line.add_child(entry["control"])
	if entry["value"] != null:
		line.add_child(entry["value"])
	container.add_child(line)
	_rows[key] = entry


## A drag shows its value as it moves and commits once, when released: every commit saves the
## settings file and re-applies the option (buffers reallocated, every grass and tree rescaled…),
## which thirty steps of a drag made stutter. A click or a keyboard step commits at once.
func _wire_slider(bar: HSlider, number: Label, option: Dictionary) -> void:
	var key : String = option["key"]
	bar.drag_started.connect(func() -> void: _dragging[key] = true)
	bar.drag_ended.connect(func(moved: bool) -> void:
		_dragging.erase(key)
		if moved:
			SettingsManager.render.set_value(key, bar.value))
	bar.value_changed.connect(func(v: float) -> void:
		number.text = _format(option, v)
		if not _dragging.has(key):
			SettingsManager.render.set_value(key, v))


func _on_changed(_keys: PackedStringArray) -> void:
	_refresh()


func _on_language_changed(_language: String) -> void:
	_refresh()


## Everything from the model: values, the preset it amounts to, and what is greyed and why.
## The *_no_signal setters, so redrawing a line never writes it back.
func _refresh() -> void:
	var render : RenderSettings = SettingsManager.render
	if _preset != null:
		var current : String = render.preset()
		_preset.select(GraphicsOptions.PRESETS.find(current) if current in GraphicsOptions.PRESETS
			else GraphicsOptions.PRESETS.size())
		_preset_line.tooltip_text = tr("%%MENU_GFX_HELP_PRESET")
		_preset.tooltip_text = _preset_line.tooltip_text
		_recommended.text = tr("%%MENU_GFX_RECOMMENDED") % [render.caps.get("adapter", "?"),
			tr(GraphicsOptions.PRESET_LABELS[render.detected()])]
	for key in _rows:
		_refresh_row(render, _rows[key])


func _refresh_row(render: RenderSettings, entry: Dictionary) -> void:
	var option : Dictionary = entry["option"]
	var key : String = option["key"]
	var value : Variant = render.effective(key)
	var why : String = render.availability(key)
	var control : Control = entry["control"]
	match option["kind"]:
		GraphicsOptions.TOGGLE:
			var button : Button = control
			button.set_pressed_no_signal(value)
			button.text = SettingsText.on_off(value)
			button.disabled = why != ""
		GraphicsOptions.CHOICE:
			var picker : OptionButton = control
			for i in picker.item_count:
				var usable : bool = render.choice_available(key, picker.get_item_metadata(i))
				picker.set_item_disabled(i, not usable)
				picker.set_item_tooltip(i, "" if usable else tr(GraphicsOptions.WHY_RENDERER))
				if GraphicsOptions.same(picker.get_item_metadata(i), value):
					picker.select(i)
			picker.disabled = why != ""
		GraphicsOptions.SLIDER:
			var bar : HSlider = control
			bar.set_value_no_signal(value)
			bar.editable = why == ""
			entry["value"].text = _format(option, value)
	# tr() here rather than the raw key: the tooltip is built when shown, and this is redrawn on
	# every language switch anyway.
	# What the option does, always; why it is greyed, first, when it is.
	var help : String = tr(option.get("help", ""))
	var tip : String = help if why == "" else tr(why) + "\n\n" + help
	# On the whole LINE, not only its caption: hovering the gap between the caption and the control
	# explains the option too. The control carries it as well, since it stops the mouse itself.
	entry["line"].tooltip_text = tip
	control.tooltip_text = tip
	entry["label"].modulate.a = _DISABLED_ALPHA if why != "" else 1.0


static func _format(option: Dictionary, value: float) -> String:
	match option.get("format", ""):
		GraphicsOptions.FORMAT_PERCENT:
			return "%d %%" % roundi(value * 100.0)
		GraphicsOptions.FORMAT_MULTIPLIER:
			return "x%.2f" % value
		GraphicsOptions.FORMAT_METERS:
			return "%d m" % roundi(value)
	return str(value)
