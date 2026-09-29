class_name StageTuning
extends RefCounted
## The tuning scene's own controls, built by composition into GraphicsOverlay.always_on(): the way
## back, at the very top of the panel, then which viewpoint and what hour, above the options.

const _BACK_FONT_SIZE : int = 18


## "‹ Back to the menu", across the top of the panel, where it is looked for first.
static func back(stage: MenuStage) -> WidgetSection:
	return WidgetSection.new("",
		func(_owner: Node, box: VBoxContainer, _factory: SettingsRowFactory) -> void:
			var button := Button.new()
			button.text = "%%SHOWCASE_BACK"
			button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.focus_mode = Control.FOCUS_NONE
			button.add_theme_font_override("font", SettingsRowFactory.FONT)
			button.add_theme_font_size_override("font_size", _BACK_FONT_SIZE)
			button.add_theme_color_override("font_color", SettingsStyle.ACTIVE_COLOR)
			button.pressed.connect(stage.exit_tuning)
			box.add_child(button))


static func section(stage: MenuStage) -> WidgetSection:
	return WidgetSection.new("%%MENU_GFX_SHOWCASE",
		func(_owner: Node, box: VBoxContainer, factory: SettingsRowFactory) -> void: _build(stage, box, factory))


static func _build(stage: MenuStage, box: VBoxContainer, factory: SettingsRowFactory) -> void:
	# Viewpoint: the set's tuning viewpoints (StageStation), glided to.
	var view_line : HBoxContainer = factory.row("%%SHOWCASE_VIEWPOINT")
	var picker : OptionButton = factory.option_button()
	var stations : Array[StageStation] = stage.tuning_stations()
	for i in stations.size():
		picker.add_item(stations[i].label, i)
		picker.set_item_metadata(i, stations[i].key)
	picker.item_selected.connect(func(i: int) -> void: stage.go_to(picker.get_item_metadata(i)))
	view_line.add_child(picker)
	box.add_child(view_line)
	# Hour: applied when the drag ends — every change turns the whole planet, and with it every chunk.
	var hour_line : HBoxContainer = factory.row("%%SHOWCASE_HOUR")
	var bar : HSlider = factory.slider(0.0, 24.0, 0.25)
	bar.value = stage.hour()
	var value : Label = factory.value_label()
	value.text = clock(bar.value)
	var dragging : Array = [false]
	bar.drag_started.connect(func() -> void: dragging[0] = true)
	bar.drag_ended.connect(func(_moved: bool) -> void:
		dragging[0] = false
		stage.set_hour(bar.value))
	bar.value_changed.connect(func(v: float) -> void:
		value.text = clock(v)
		if not dragging[0]:
			stage.set_hour(v))
	hour_line.add_child(bar)
	hour_line.add_child(value)
	box.add_child(hour_line)


## 17.25 -> "17:15".
static func clock(hours: float) -> String:
	var minutes : int = roundi(fposmod(hours, 24.0) * 60.0)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [(minutes / 60) % 24, minutes % 60]
