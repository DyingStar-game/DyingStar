class_name MenuStage
extends Node3D
## The main menu, set on Tarsis 3: the menu UI over a live 3D outpost, the camera gliding to a new
## station for each screen (home, settings, graphics…), and a tuning scene where the graphics options
## are compared on real ground, near and far, at any hour.
##
## The composition root of the stage: it asks whether the terrain tile service answers
## (TileServiceProbe — without it the ground is flat and the buildings float), and only then loads
## the world — menu_stage_world.tscn, the star, Tarsis 3 and its Outpost, all placed in the editor —
## and adds the sky (ClientSky, the player's own) around its camera rig. Unreachable, or switched off
## in Settings > General, it loads nothing and the menu keeps its still image. The menu UI (MainPage)
## knows nothing of the stage: it only says which screen is showing.
##
## The global state it borrows (universe root, frozen clock, mouse) goes back in _exit_tree
## (StageSession); entering the game frees the whole stage with the scene change.

## The set: edit it in Godot (move, add, remove props, figures, trucks and viewpoints).
const WORLD_SCENE : String = "res://levels/menu_stage/menu_stage_world.tscn"
const PLANET_NAME : String = "tarsis_3"
## Sunrise: the sun just clear of the horizon in the morning — long shadows, a warm sky, the lamps
## still on. Set by the sun's height rather than an hour, which could fall in the dark in winter.
const MENU_SUN_ELEVATION_DEG : float = 5.0
## Longest wait for the first ground and a settled sun before the menu shows anyway.
const READY_TIMEOUT_S : float = 10.0
## The graphics panel covers the left quarter of the screen while tuning: the view turns this much to
## the left of each viewpoint's target, so what it frames stands in the visible part.
const TUNING_YAW_DEG : float = 16.0
## Far tiles keep arriving after the first ground: the props are put back on it for this long.
const RESNAP_FOR_S : float = 60.0

## The stage on show, for the Graphics page's "Tuning scene" button. Null outside the main menu.
static var active : MenuStage = null

var _session := StageSession.new()
var _probe : TileServiceProbe = null
var _planet : Planet = null
var _rig : StageRig = null
var _outpost : StageOutpost = null
var _anchor : Vector3 = Vector3.ZERO
var _hour : float = 12.0
var _live : bool = false
var _tuning : OverlayPanel = null
## The station to glide back to when the tuning scene closes: where it was opened from.
var _tuning_from : StringName = &"home"
var _resnap_left : float = 0.0
var _resnap_tick : float = 0.0

@onready var _menu : MainPage = $MainPage


func _ready() -> void:
	active = self
	_menu.screen_changed.connect(go_to)
	_menu.tuning_requested.connect(enter_tuning.bind(&"home"))
	if not SettingsManager.render.is_menu_stage_enabled():
		print("[MenuStage] switched off in Settings > General: the menu keeps its still image.")
		return
	# The splash first, over the menu: its buttons appear with the stage, not before it.
	_splash(true)
	_probe = TileServiceProbe.new()
	_probe.start(PLANET_NAME)


func _exit_tree() -> void:
	if _probe != null:
		_probe.wait()
	_session.end()
	if active == self:
		active = null


## The 3D stage is up (not the still-image fallback).
func is_live() -> bool:
	return _live


func _process(delta: float) -> void:
	if _probe != null and _probe.is_done():
		_probe.wait()  # a finished pool task must still be waited for, or it leaks (and exit crashes)
		var reachable : bool = _probe.ok
		_probe = null
		_progress(0.1)
		if reachable:
			_build()
		else:
			_splash(false)
			print("[MenuStage] terrain tile service unreachable: the menu keeps its still image.")
	if _live and _resnap_left > 0.0:
		_resnap_tick += delta
		if _resnap_tick >= 1.0:
			_resnap_left -= _resnap_tick
			_resnap_tick = 0.0
			_outpost.resnap()


func _unhandled_input(event: InputEvent) -> void:
	if _tuning != null and event.is_action_pressed("pause"):
		exit_tuning()
		get_viewport().set_input_as_handled()


## Glide to a viewpoint of the set (a menu screen's, or a tuning one).
func go_to(key: StringName) -> void:
	if not _live or not is_instance_valid(_rig):
		return
	var station : StageStation = _outpost.station(key)
	# A settings tab without its own viewpoint shares the Settings one.
	if station == null and String(key).begins_with("settings_"):
		station = _outpost.station(&"settings")
	if station != null:
		_rig.glide_to_view(station.transform)


## The tuning scene's viewpoints, in the set's order.
func tuning_stations() -> Array[StageStation]:
	if _outpost == null:
		return []
	return _outpost.stations().filter(func(s: StageStation) -> bool: return s.is_tuning())


func hour() -> float:
	return _hour


func set_hour(value: float) -> void:
	_hour = value
	if _live:
		StageClock.set_hour(_planet, _anchor, value)


## The tuning scene: the menu UI steps aside for the graphics panel and its viewpoints. `from`: the
## station to come back to (the home screen's button, or Settings > Graphics).
func enter_tuning(from: StringName = &"settings_graphics") -> void:
	if not _live or _tuning != null:
		return
	_tuning_from = from
	_tuning = GraphicsOverlay.always_on([StageTuning.section(self)])
	add_child(_tuning)
	_rig.yaw_offset_deg = TUNING_YAW_DEG
	_menu.set_interface_hidden(true)
	var first : Array[StageStation] = tuning_stations()
	if not first.is_empty():
		go_to(first[0].key)


func exit_tuning() -> void:
	if _tuning == null:
		return
	_tuning.queue_free()
	_tuning = null
	_rig.yaw_offset_deg = 0.0
	_sunrise()
	_menu.set_interface_hidden(false)
	go_to(_tuning_from)


func _build() -> void:
	# Let the splash paint before the planet's set-up holds the main thread for a few seconds.
	await get_tree().process_frame
	await get_tree().process_frame
	var world : Node3D = load(WORLD_SCENE).instantiate()
	# Before the world enters the tree: the planet places itself for the (frozen) clock in its _ready.
	_session.begin(world)
	add_child(world)
	_progress(0.5)  # the planet's set-up held the main thread: the bar jumps rather than crawls
	_planet = world.get_node("Tarsis3")
	_outpost = _planet.get_node("Outpost")
	var ground_ready : Array = [false]
	if _planet.planet_terrain != null:
		_planet.planet_terrain.initial_chunks_ready.connect(func() -> void: ground_ready[0] = true,
			CONNECT_ONE_SHOT)
	_anchor = _outpost.anchor_local()
	_rig = StageRig.new()
	_planet.add_child(_rig)
	_live = true  # from here go_to() and set_hour() act
	var home : StageStation = _outpost.station(&"home")
	if home != null:
		_rig.frame_view(home.transform)
	ClientSky.attach(_rig)
	_sunrise()
	var waited : float = 0.0
	# Only the ground: the sun's `settled` waits for a player's BODY to align with the vertical, which
	# a camera rig aiming at a point never does.
	while waited < READY_TIMEOUT_S and not ground_ready[0]:
		await get_tree().process_frame
		waited += get_process_delta_time()
		# The ground: chunks built out of those asked for, or the time left, whichever is further.
		var terrain : PlanetTerrain = _planet.planet_terrain
		var built : float = 0.0
		if terrain != null and terrain.desired_chunk_count() > 0:
			built = float(terrain.active_chunk_count()) / terrain.desired_chunk_count()
		_progress(0.5 + 0.5 * maxf(built, waited / READY_TIMEOUT_S))
	_outpost.start(_planet.planet_data.radius, _planet.planet_data.crack_aware_surface_dist)
	_resnap_left = RESNAP_FOR_S
	_menu.set_stage_mode(true)
	_splash(false)
	print("[MenuStage] live on %s after %.1f s (ground %s)" % [PLANET_NAME, waited,
		"ready" if ground_ready[0] else "late"])


## The menu's light: the sun just risen (MENU_SUN_ELEVATION_DEG), whatever the season.
func _sunrise() -> void:
	var hour_set : float = StageClock.set_sun_elevation(_planet, _anchor, MENU_SUN_ELEVATION_DEG)
	_hour = hour_set if hour_set >= 0.0 else 12.0


## The loading splash, saying just "Loading…" while the menu builds; its own "Loading the
## Universe…" is given back for the game.
func _splash(on: bool) -> void:
	if on:
		LoadingSplash.show(get_tree(), "%%MENU_STAGE_LOADING")
	else:
		LoadingSplash.hide(get_tree())
		LoadingSplash.say(get_tree(), "%%MENU_LOADING")


func _progress(value: float) -> void:
	LoadingSplash.progress(get_tree(), value)
