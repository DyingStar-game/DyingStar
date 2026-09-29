class_name MenuStage
extends Node3D
## The main menu, set on Tarsis 3: the menu UI over a live 3D outpost, the camera gliding to a new
## station for each screen (home, settings, graphics…), and a tuning scene where the graphics options
## are compared on real ground, near and far, at any hour.
##
## The composition root of the stage: it asks whether the terrain tile service answers
## (TileServiceProbe — without it the ground is flat and the buildings float), and only then builds
## the planet, the sky (ClientSky, the player's own), the camera rig and the props. Unreachable, it
## builds nothing and the menu keeps its still image. The menu UI (MainPage) knows nothing of the
## stage: it only says which screen is showing.
##
## The global state it borrows (universe root, frozen clock, mouse) goes back in _exit_tree
## (StageSession); entering the game frees the whole stage with the scene change.

const PLANET_SCENE : String = "res://scenes/systems/tarsis/tarsis_3.tscn"
const STAR_SCENE : String = "res://scenes/_universe/environment/space/star.tscn"
const PLANET_NAME : String = "tarsis_3"
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
var _props : StageProps = null
var _frame : SurfaceFrame = null
var _anchor : Vector3 = Vector3.ZERO
var _line_deg : float = 0.0
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
		if reachable:
			_build()
		else:
			print("[MenuStage] terrain tile service unreachable: the menu keeps its still image.")
	if _live and _resnap_left > 0.0:
		_resnap_tick += delta
		if _resnap_tick >= 1.0:
			_resnap_left -= _resnap_tick
			_resnap_tick = 0.0
			_props.resnap()


func _unhandled_input(event: InputEvent) -> void:
	if _tuning != null and event.is_action_pressed("pause"):
		exit_tuning()
		get_viewport().set_input_as_handled()


## Glide to a station of StageLayout (a menu screen, or a tuning viewpoint).
func go_to(key: StringName) -> void:
	var station : Dictionary = StageLayout.station(key)
	if not _live or station.is_empty() or not is_instance_valid(_rig):
		return
	_rig.glide_to(_at(station["eye"]), _at(station["look"]))


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
	go_to(StageLayout.tuning_stations()[0]["key"])


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
	_splash(true)
	# Let the splash paint before the planet's set-up holds the main thread for a few seconds.
	await get_tree().process_frame
	await get_tree().process_frame
	_session.begin(self)
	var star : Node3D = load(STAR_SCENE).instantiate()
	star.name = "Star"
	add_child(star)
	_planet = load(PLANET_SCENE).instantiate()
	add_child(_planet)
	var ground_ready : Array = [false]
	if _planet.planet_terrain != null:
		_planet.planet_terrain.initial_chunks_ready.connect(func() -> void: ground_ready[0] = true,
			CONNECT_ONE_SHOT)
	_anchor = (_planet.get_node(StageLayout.ANCHOR) as Node3D).position
	_frame = SurfaceFrame.new(_anchor, _planet.planet_data.radius, _planet.planet_data.crack_aware_surface_dist)
	_line_deg = _frame.bearing_to((_planet.get_node(StageLayout.LINE_TOWARD) as Node3D).position)
	_rig = StageRig.new()
	_planet.add_child(_rig)
	_live = true  # from here go_to() and set_hour() act
	var home : Dictionary = StageLayout.station(&"home")
	_rig.frame(_at(home["eye"]), _at(home["look"]))
	ClientSky.attach(_rig)
	_sunrise()
	var waited : float = 0.0
	# Only the ground: the sun's `settled` waits for a player's BODY to align with the vertical, which
	# a camera rig aiming at a point never does.
	while waited < READY_TIMEOUT_S and not ground_ready[0]:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_props = StageProps.new()
	_planet.add_child(_props)
	_props.populate(_frame, _line_deg)
	_resnap_left = RESNAP_FOR_S
	_menu.set_stage_mode(true)
	_splash(false)
	print("[MenuStage] live on %s after %.1f s (ground %s)" % [PLANET_NAME, waited,
		"ready" if ground_ready[0] else "late"])


## The menu's light: the sun just risen (StageLayout.MENU_SUN_ELEVATION_DEG), whatever the season.
func _sunrise() -> void:
	var hour_set : float = StageClock.set_sun_elevation(_planet, _anchor, StageLayout.MENU_SUN_ELEVATION_DEG)
	_hour = hour_set if hour_set >= 0.0 else 12.0


## A planet-local point from a layout triple [distance, bearing from the line, height above ground].
func _at(spot: Array) -> Vector3:
	return _frame.point(float(spot[0]), _line_deg + float(spot[1]), float(spot[2]))


## The game's loading splash (GameOrchestrator puts it on the root, hidden, at boot).
func _splash(on: bool) -> void:
	var loading : Node = get_tree().root.get_node_or_null("Loading")
	var screen : Node = loading.get_node_or_null("LoadingScreen") if loading != null else null
	if screen != null:
		screen.visible = on
