class_name RenderLab
extends RefCounted
## Development panel to compare rendering choices live, in the running game (Alt+G, debug and editor builds):
## tone mapper, exposure, the sun's soft shadows, the screen-space effects and a VoxelGI baked in the nearest
## building. An OverlayPanel like the graphics overlay: hold AltGr to use the mouse on it, F7 leaves it out of
## the photo.
##
## Every change is applied to the live Environment and sun only: nothing is saved, nothing reaches settings.ini,
## and a respawn (a new Environment) starts again from the game's own look. The client.ini measurement keys
## (debug_tonemap…) set the starting values; this moves them. A development tool, never shown to a player:
## plain strings, nothing to translate.

const ACTION := &"debug_render_lab"
const WIDTH_PX : float = 380.0
## How far a building may stand from the camera to get the VoxelGI, metres.
const BUILDING_RANGE_M := 120.0
## "Every building around": the radius, metres.
const AROUND_M := 80.0
## By path, not by class name: a class added without a re-import is not known by its name yet.
const InteriorGiScript := preload("res://scenes/common/interior_gi.gd")
const DirectorScript := preload("res://scenes/common/interior_gi_director.gd")

const TONE_MAPPERS : Array = [
	[Environment.TONE_MAPPER_LINEAR, "Linear"],
	[Environment.TONE_MAPPER_REINHARDT, "Reinhard"],
	[Environment.TONE_MAPPER_FILMIC, "Filmic"],
	[Environment.TONE_MAPPER_ACES, "ACES"],
	[Environment.TONE_MAPPER_AGX, "AgX (the game's)"],
]

## Open or closed, for every lab: the key flips it.
static var open : bool = false


## Register Alt+G when the project has no action of that name: no project.godot edit for a debug key.
static func register_action() -> void:
	if not enabled() or InputMap.has_action(ACTION):
		return
	InputMap.add_action(ACTION)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_G
	key.alt_pressed = true
	InputMap.action_add_event(ACTION, key)


## Offered in debug and editor builds only.
static func enabled() -> bool:
	return OS.is_debug_build()


## The panel for [param atmosphere]'s world (the AtmosphereRenderer; typed Node to keep the two scripts from
## loading each other) and [param sun]. Hidden until the key opens it.
static func create(atmosphere: Node, sun: DirectionalLight3D) -> OverlayPanel:
	# Left edge: the right one holds the debug readouts and their red alerts (DevOverlay).
	var panel := OverlayPanel.new(OverlayPanel.Edge.LEFT, WIDTH_PX,
			"RENDER LAB — Alt+G to close, hold AltGr to use the mouse. Nothing is saved.", true)
	panel.name = "RenderLab"
	panel.enabled_rule = func() -> bool: return open
	var lab := _Lab.new(atmosphere, sun)
	panel.add_section(ReadoutSection.new("", PerfReadout.lines, 0.25), true)
	panel.add_section(WidgetSection.new("Image", lab.build_image))
	panel.add_section(WidgetSection.new("Sun shadows", lab.build_sun))
	panel.add_section(WidgetSection.new("Screen effects", lab.build_screen))
	panel.add_section(WidgetSection.new("Global illumination (VoxelGI)", lab.build_gi))
	panel.set_meta(&"lab", lab)  # keeps the builder (and its state) alive as long as the panel
	return panel


## The state and the row builders behind one panel.
class _Lab:
	extends RefCounted

	var _atmosphere : Node
	var _sun : DirectionalLight3D
	var _gi_status : Label
	var _gi_energy : float = 1.0
	var _gi_interior : bool = false
	var _gi_on : bool = true
	var _gi_subdiv : VoxelGI.Subdiv = InteriorGiScript.DEFAULT_SUBDIV

	func _init(atmosphere: Node, sun: DirectionalLight3D) -> void:
		_atmosphere = atmosphere
		_sun = sun

	## The Environment of the world as it is now (a respawn replaces it), or null.
	func env() -> Environment:
		if not is_instance_valid(_atmosphere) or not _atmosphere.is_inside_tree():
			return null
		var world := _atmosphere.get_viewport().world_3d
		return world.environment if world != null else null

	func build_image(_owner: Node, box: VBoxContainer, factory: SettingsRowFactory) -> void:
		var e := env()
		var mapper := factory.option_button()
		for i in TONE_MAPPERS.size():
			mapper.add_item(TONE_MAPPERS[i][1], TONE_MAPPERS[i][0])
		if e != null:
			mapper.select(mapper.get_item_index(e.tonemap_mode))
		mapper.item_selected.connect(func(index: int) -> void:
			var now := env()
			if now != null:
				now.tonemap_mode = mapper.get_item_id(index) as Environment.ToneMapper)
		box.add_child(_line(factory, "Tone mapper", mapper))
		_slider(box, factory, "Exposure", 0.25, 4.0, 0.05, e.tonemap_exposure if e != null else 1.0,
				func(v: float) -> void:
					var now := env()
					if now != null:
						now.tonemap_exposure = v)
		_slider(box, factory, "White point", 1.0, 16.0, 0.5, e.tonemap_white if e != null else 1.0,
				func(v: float) -> void:
					var now := env()
					if now != null:
						now.tonemap_white = v)
		# AgX's own two: contrast (1.25 = Godot's default; higher = darker darks, brighter brights) and its white
		# point (16.29 by default; ~6 and up for realistic light). Read by name: absent from an older engine.
		_property_slider(box, factory, "AgX contrast", &"tonemap_agx_contrast", 0.5, 2.5, 0.05, 1.25)
		_property_slider(box, factory, "AgX white", &"tonemap_agx_white", 2.0, 20.0, 0.25, 16.29)
		# After the tone mapper, whichever it is: the "AgX but livelier" knobs (adjustment_* needs the switch on).
		_property_slider(box, factory, "Saturation", &"adjustment_saturation", 0.0, 2.0, 0.05, 1.0, true)
		_property_slider(box, factory, "Contrast", &"adjustment_contrast", 0.5, 1.5, 0.02, 1.0, true)

	## A slider on one Environment property, starting from its current value; [param adjustment] also turns the
	## Environment's colour adjustment on, which the adjustment_* properties need.
	func _property_slider(box: VBoxContainer, factory: SettingsRowFactory, caption: String, property: StringName,
			low: float, high: float, step: float, fallback: float, adjustment: bool = false) -> void:
		var e := env()
		if e != null and not property in e:
			return
		var start: float = float(e.get(property)) if e != null else fallback
		_slider(box, factory, caption, low, high, step, start, func(v: float) -> void:
			var now := env()
			if now == null:
				return
			if adjustment:
				now.adjustment_enabled = true
			now.set(property, v))

	func build_sun(_owner: Node, box: VBoxContainer, factory: SettingsRowFactory) -> void:
		var has_sun := is_instance_valid(_sun)
		_toggle(box, factory, "Blend cascades", has_sun and _sun.directional_shadow_blend_splits,
				func(on: bool) -> void:
					if is_instance_valid(_sun):
						_sun.directional_shadow_blend_splits = on)
		_slider(box, factory, "Sun size (deg)", 0.0, 2.0, 0.05, _sun.light_angular_distance if has_sun else 0.0,
				func(v: float) -> void:
					if is_instance_valid(_sun):
						_sun.light_angular_distance = v)

	func build_screen(_owner: Node, box: VBoxContainer, factory: SettingsRowFactory) -> void:
		var e := env()
		for item: Array in [["SSAO (contact shadows)", &"ssao_enabled"], ["SSIL (screen bounce)", &"ssil_enabled"],
				["SSR (reflections)", &"ssr_enabled"], ["Glow", &"glow_enabled"]]:
			var property : StringName = item[1]
			_toggle(box, factory, item[0], e != null and bool(e.get(property)), func(on: bool) -> void:
				var now := env()
				if now != null:
					now.set(property, on))

	func build_gi(_owner: Node, box: VBoxContainer, factory: SettingsRowFactory) -> void:
		_toggle(box, factory, "Automatic (on approach)", DirectorScript.auto, func(on: bool) -> void:
			DirectorScript.auto = on
			_apply_gi())
		var quality := factory.option_button()
		for item: Array in [[VoxelGI.SUBDIV_64, "64 (coarse, fast)"], [VoxelGI.SUBDIV_128, "128 (default)"],
				[VoxelGI.SUBDIV_256, "256 (fine)"], [VoxelGI.SUBDIV_512, "512 (very fine, slow)"]]:
			quality.add_item(item[1], item[0])
		quality.select(quality.get_item_index(_gi_subdiv))
		quality.item_selected.connect(func(index: int) -> void:
			_gi_subdiv = quality.get_item_id(index) as VoxelGI.Subdiv)
		box.add_child(_line(factory, "Grid (next bake)", quality))
		var bake := factory.button("Bake")
		bake.pressed.connect(_bake_nearest)
		box.add_child(_line(factory, "Nearest building", bake))
		var bake_all := factory.button("Bake")
		bake_all.pressed.connect(_bake_around)
		box.add_child(_line(factory, "Every building within %d m" % int(AROUND_M), bake_all))
		_gi_status = factory.value_label()
		_gi_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_gi_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_gi_status.custom_minimum_size = Vector2.ZERO
		_gi_status.text = "None baked yet."
		box.add_child(_gi_status)
		_toggle(box, factory, "VoxelGI on", true, func(on: bool) -> void:
			_gi_on = on
			_apply_gi())
		_slider(box, factory, "Energy", 0.0, 4.0, 0.05, 1.0, func(v: float) -> void:
			_gi_energy = v
			_apply_gi())
		_toggle(box, factory, "Interior (no sky light)", false, func(on: bool) -> void:
			_gi_interior = on
			_apply_gi())

	## Bake a VoxelGI in the building nearest the camera, within BUILDING_RANGE_M.
	func _bake_nearest() -> void:
		var found := _buildings_within(BUILDING_RANGE_M)
		if found.is_empty():
			_gi_status.text = "No building within %d m." % int(BUILDING_RANGE_M)
			return
		var started := Time.get_ticks_msec()
		var gi := _bake(found[0][1])
		if gi == null:
			_gi_status.text = "%s: no mesh, or too large." % found[0][1].name
			return
		_gi_status.text = "%s (%.0f m away): %.0f x %.0f x %.0f m, %d ms." % [found[0][1].name, found[0][0], gi.size.x,
				gi.size.y, gi.size.z, Time.get_ticks_msec() - started]

	## Bake a VoxelGI in every building within AROUND_M: the whole street lit by bounce, to judge the look and
	## the cost together (each one is a separate probe; the game would only keep the one the camera is in).
	func _bake_around() -> void:
		var started := Time.get_ticks_msec()
		var count := 0
		for pair: Array in _buildings_within(AROUND_M):
			if _bake(pair[1]) != null:
				count += 1
		_gi_status.text = "%d building(s) within %d m baked, %d ms." % [count, int(AROUND_M),
				Time.get_ticks_msec() - started]

	## [distance, building] for each building (a node that stands on a TerrainPad) within [param range_m] of
	## the camera, nearest first.
	func _buildings_within(range_m: float) -> Array:
		var camera := _atmosphere.get_viewport().get_camera_3d()
		var found : Array = []
		if camera == null:
			return found
		for pad in _atmosphere.get_tree().root.find_children("TerrainPad", "", true, false):
			var building := pad.get_parent() as Node3D
			if building == null:
				continue
			# Both positions are ~3e10 m out: subtract them (doubles) before measuring.
			var d := (camera.global_position - building.global_position).length()
			if d < range_m:
				found.append([d, building])
		found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		return found

	## The building's VoxelGI at the chosen grid, rebuilt when it was baked at another one.
	func _bake(building: Node3D) -> VoxelGI:
		var old := building.get_node_or_null(NodePath(InteriorGiScript.NODE_NAME)) as VoxelGI
		if old != null and old.subdiv != _gi_subdiv:
			building.remove_child(old)
			old.queue_free()
		var gi : VoxelGI = InteriorGiScript.ensure(building, _gi_subdiv)
		_apply_gi()
		return gi

	## Every VoxelGI of InteriorGi, baked here or by the director on approach. With the director on, it decides
	## which are shown (the nearest) and only reads the on/off switch; otherwise the switch applies directly.
	func _apply_gi() -> void:
		DirectorScript.shown = _gi_on
		for node in _atmosphere.get_tree().get_nodes_in_group(InteriorGiScript.GROUP):
			var gi := node as VoxelGI
			if not DirectorScript.auto:
				gi.visible = _gi_on
			if gi.data != null:
				gi.data.energy = _gi_energy
				gi.data.interior = _gi_interior

	func _line(factory: SettingsRowFactory, caption: String, control: Control) -> HBoxContainer:
		var line := factory.row(caption)
		line.add_child(control)
		return line

	func _toggle(box: VBoxContainer, factory: SettingsRowFactory, caption: String, value: bool,
			changed: Callable) -> void:
		var switch := factory.toggle()
		switch.button_pressed = value
		switch.text = "On" if value else "Off"
		switch.toggled.connect(func(on: bool) -> void:
			switch.text = "On" if on else "Off"
			changed.call(on))
		box.add_child(_line(factory, caption, switch))

	func _slider(box: VBoxContainer, factory: SettingsRowFactory, caption: String, low: float, high: float,
			step: float, value: float, changed: Callable) -> void:
		var bar := factory.slider(low, high, step)
		var shown := factory.value_label()
		bar.value = value
		shown.text = "%.2f" % value
		bar.value_changed.connect(func(v: float) -> void:
			shown.text = "%.2f" % v
			changed.call(v))
		var line := _line(factory, caption, bar)
		line.add_child(shown)
		box.add_child(line)
