class_name VrComfortRows
extends RefCounted
## The "VR comfort" lines of Settings > General, built from code below the page's own lines, in VR only
## (General page). Each line writes its setting (VrComfortSettings) as it changes, and the rig plays it
## at once: there is nothing to apply.

## Choice lines: setting key -> its caption and its [value, caption] choices.
const CHOICES := {
	"turn": ["%%MENU_VR_TURN", [[VrComfortSettings.TURN_SNAP, "%%MENU_VR_TURN_SNAP"],
			[VrComfortSettings.TURN_SMOOTH, "%%MENU_VR_TURN_SMOOTH"]]],
	"hand": ["%%MENU_VR_HAND", [[VrComfortSettings.HAND_RIGHT, "%%MENU_VR_HAND_RIGHT"],
			[VrComfortSettings.HAND_LEFT, "%%MENU_VR_HAND_LEFT"]]],
	"walk": ["%%MENU_VR_WALK", [[VrComfortSettings.WALK_HEAD, "%%MENU_VR_WALK_HEAD"],
			[VrComfortSettings.WALK_HAND, "%%MENU_VR_WALK_HAND"]]],
}
## Slider lines: setting key -> caption, min, max, step, how its value reads.
const SLIDERS := {
	"snap_deg": ["%%MENU_VR_SNAP_ANGLE", VrComfortSettings.SNAP_MIN, VrComfortSettings.SNAP_MAX,
			VrComfortSettings.SNAP_STEP, "%d°"],
	"smooth_deg_s": ["%%MENU_VR_SMOOTH_SPEED", VrComfortSettings.SMOOTH_MIN, VrComfortSettings.SMOOTH_MAX,
			VrComfortSettings.SMOOTH_STEP, "%d°/s"],
}
## On / Off lines: setting key -> caption.
const TOGGLES := {
	"vignette": "%%MENU_VR_VIGNETTE",
	"seated": "%%MENU_VR_SEATED",
}
## The lines, in their order on the page.
const ORDER: Array[String] = ["turn", "snap_deg", "smooth_deg_s", "vignette", "hand", "walk", "seated"]


## Add the heading and the lines to [param container], bound to [param settings].
static func build(container: Container, settings: VrComfortSettings) -> void:
	var factory := SettingsRowFactory.new()
	container.add_child(factory.header("%%MENU_VR_HEADER"))
	for key: String in ORDER:
		var line: HBoxContainer
		if CHOICES.has(key):
			line = _choice(factory, settings, key)
		elif SLIDERS.has(key):
			line = _slider(factory, settings, key)
		else:
			line = _toggle(factory, settings, key)
		line.name = "Vr_" + key
		container.add_child(line)


static func _choice(factory: SettingsRowFactory, settings: VrComfortSettings, key: String) -> HBoxContainer:
	var line := factory.row(CHOICES[key][0])
	var picker := factory.option_button()
	var choices: Array = CHOICES[key][1]
	for i in choices.size():
		picker.add_item(choices[i][1], i)
		picker.set_item_metadata(i, choices[i][0])
		if settings.value(key) == choices[i][0]:
			picker.select(i)
	picker.item_selected.connect(func(i: int) -> void: settings.set_value(key, picker.get_item_metadata(i)))
	line.add_child(picker)
	return line


static func _slider(factory: SettingsRowFactory, settings: VrComfortSettings, key: String) -> HBoxContainer:
	var spec: Array = SLIDERS[key]
	var line := factory.row(spec[0])
	var bar := factory.slider(spec[1], spec[2], spec[3])
	var number := factory.value_label()
	bar.set_value_no_signal(settings.value(key))
	number.text = spec[4] % roundi(bar.value)
	bar.value_changed.connect(func(v: float) -> void:
		number.text = spec[4] % roundi(v)
		settings.set_value(key, v))
	line.add_child(bar)
	line.add_child(number)
	return line


static func _toggle(factory: SettingsRowFactory, settings: VrComfortSettings, key: String) -> HBoxContainer:
	var line := factory.row(TOGGLES[key])
	var button := factory.toggle()
	button.button_pressed = settings.value(key)
	button.text = SettingsText.on_off(button.button_pressed)
	button.toggled.connect(func(on: bool) -> void:
		button.text = SettingsText.on_off(on)
		settings.set_value(key, on))
	line.add_child(button)
	return line
