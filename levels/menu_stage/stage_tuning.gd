class_name StageTuning
extends RefCounted
## The tuning scene's own controls, as one section of the graphics panel: which viewpoint, what hour,
## and the way back. Built by composition into GraphicsOverlay.always_on(), above the options.


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
	var back_line : HBoxContainer = factory.row("")
	var back : Button = factory.button("%%SHOWCASE_BACK")
	back.pressed.connect(stage.exit_tuning)
	back_line.add_child(back)
	box.add_child(back_line)


## 17.25 -> "17:15".
static func clock(hours: float) -> String:
	var minutes : int = roundi(fposmod(hours, 24.0) * 60.0)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [(minutes / 60) % 24, minutes % 60]
