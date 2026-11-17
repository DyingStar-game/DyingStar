class_name WeatherPanel
extends RefCounted
## A dev panel (Alt+P, Globals dev tool "debug_weather_panel") with one switch per layer of the
## weather's and the atmosphere's shaders: the sky dome (sky.gdshader) and the aerial pass between the
## eye and the ground (aerial_perspective.gdshader, which also draws the dust and the storms). A switch
## turned off forces that layer's parameter to nothing, over whatever the code pushed this frame
## (AtmosphereRenderer applies overrides() last), so any artefact can be pinned to its layer by
## clicking, the others left as they are. Hold AltGr to use the mouse (OverlayPanel).
##
## Built by composition on OverlayPanel like GraphicsOverlay; the switches are statics so the
## renderer reads them without a reference to the panel, as it does WeatherBench's.

const WIDTH_PX: float = 430.0
const SKY: StringName = &"sky"
const AERIAL: StringName = &"aerial"
## [what the line says, which material, the parameter, its value while the layer is off].
const LAYERS: Array = [
	["aerial: air (Rayleigh)", AERIAL, &"rayleigh_beta", Vector3.ZERO],
	["aerial: veil, 1-D profile (Mie)", AERIAL, &"mie_beta", Vector3.ZERO],
	["aerial: near dust layer", AERIAL, &"dust_density", 0.0],
	["aerial: near dust, building masks (clear inside)", AERIAL, &"dust_mask_count", 0],
	["aerial: whole cloud layer (storms + cloud sea, no march)", AERIAL, &"cloud_on", 0],
	["aerial: dust storms (volume)", AERIAL, &"cloud_storms_on", 0],
	["aerial: cloud sea (volume)", AERIAL, &"cloud_deck_on", 0],
	["aerial: planet map (biome colour, ground past the grid)", AERIAL, &"cloud_planet_on", 0],
	["aerial: absorption", AERIAL, &"absorption_beta", Vector3.ZERO],
	["sky: air (Rayleigh)", SKY, &"rayleigh_beta", Vector3.ZERO],
	["sky: veil (Mie)", SKY, &"mie_beta", Vector3.ZERO],
	["sky: veil multiple scattering", SKY, &"mie_ms", 0.0],
	["sky: storm slab", SKY, &"storm_slab_beta", Vector3.ZERO],
	["sky: absorption", SKY, &"absorption_beta", Vector3.ZERO],
	["sky: local ground (rays stop on it)", SKY, &"ground_stop_m", 0.0],
	["sky: sun disc", SKY, &"star_brightness", 0.0],
]

## Shown or not (Alt+P).
static var open: bool = false
## The layers switched off, by index in LAYERS.
static var off: Dictionary = {}


## The panel, hidden until Alt+P.
static func create() -> OverlayPanel:
	var panel := OverlayPanel.new(OverlayPanel.Edge.LEFT, WIDTH_PX, "%%MENU_GFX_OVERLAY_HINT", true)
	panel.enabled_rule = func() -> bool: return open
	panel.add_section(WidgetSection.new("%%DEBUG_WEATHER_PANEL", _build))
	return panel


## Forced parameters of [param material] (SKY or AERIAL), {name: value}, for the layers switched off.
static func overrides(material: StringName) -> Dictionary:
	var out: Dictionary = {}
	for i: int in off:
		var layer: Array = LAYERS[i]
		if layer[1] == material:
			out[layer[2]] = layer[3]
	return out


## Turn layer [param index] off ([param on] false) or back on.
static func set_layer(index: int, on: bool) -> void:
	if on:
		off.erase(index)
	else:
		off[index] = true


static func _build(_owner: Node, content: VBoxContainer, factory: SettingsRowFactory) -> void:
	for i in LAYERS.size():
		var line: HBoxContainer = factory.row(LAYERS[i][0])
		var switch: Button = factory.toggle()
		switch.button_pressed = not off.has(i)
		switch.text = "on" if switch.button_pressed else "off"
		switch.toggled.connect(func(pressed: bool) -> void:
			set_layer(i, pressed)
			switch.text = "on" if pressed else "off")
		line.add_child(switch)
		content.add_child(line)
	var all_on: Button = factory.button("all on")
	all_on.pressed.connect(func() -> void:
		off.clear()
		for line: Node in content.get_children():
			for child: Node in line.get_children():
				if child is Button and (child as Button).toggle_mode:
					(child as Button).set_pressed_no_signal(true)
					(child as Button).text = "on")
	content.add_child(all_on)
