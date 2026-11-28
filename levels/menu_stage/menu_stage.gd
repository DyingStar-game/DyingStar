class_name MenuStage
extends Node3D
## The main menu, set on Tarsis 3: the menu UI over a live 3D outpost, the camera gliding to a new
## station for each screen (home, settings, graphics…). The settings keep to the left half of the
## screen, so a graphics option is judged on the live scene beside it.
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
## The planet's node in WORLD_SCENE.
const PLANET_NODE : StringName = &"Tarsis3"
## Sunrise: the sun just clear of the horizon in the morning — long shadows, a warm sky, the lamps
## still on. Set by the sun's height rather than an hour, which could fall in the dark in winter.
const MENU_SUN_ELEVATION_DEG : float = 5.0
## Longest wait for the first ground and a settled sun before the menu shows anyway.
const READY_TIMEOUT_S : float = 10.0
## Far tiles keep arriving after the first ground: the props are put back on it for this long.
const RESNAP_FOR_S : float = 60.0
## The stage joins this group, so Settings > Graphics can find it for its hour slider.
const GROUP : StringName = &"menu_stage"
## The stage is in this group too while it is being built, from asking the tile service to live (or given
## up): the menu's warm-up waits for it to leave (Warmup.waits_for_menu_stage).
const BUILDING_GROUP : StringName = &"menu_stage_building"
## Development: enter the universe as soon as the stage is up, as a click on "Enter" would (a measured
## game start, the same every run). Command line only, after `--`.
const AUTO_ENTER_ARG : String = "--auto-enter"

var _session := StageSession.new()
var _probe : TileServiceProbe = null
var _planet : Planet = null
var _rig : StageRig = null
var _outpost : StageOutpost = null
var _anchor : Vector3 = Vector3.ZERO
## The sunrise hour, solved once (a hundred placements of the planet).
var _sunrise_hour : float = -1.0
var _hour : float = 12.0
var _live : bool = false
var _resnap_left : float = 0.0
var _resnap_tick : float = 0.0
var _ground : DrawnGround = null
## The WorkerThreadPool task this stage waits for (_load_world, _pipelines_compiled), -1 when none runs.
var _pending_task : int = -1

@onready var _menu : MainPage = $MainPage


func _ready() -> void:
	add_to_group(GROUP)
	_menu.screen_changed.connect(go_to)
	BootTrace.start(get_tree())  # the start, step by step, in the log (BootTrace)
	Warmup.start(get_tree())  # what the game needs first, loaded while the menu shows (stage on or off)
	# The village bench is set on this stage: without it the bench never starts and the game idles on the menu.
	if not SettingsManager.render.is_menu_stage_enabled() and not VillageBench.wanted():
		print("[MenuStage] switched off in Settings > General%s: the menu keeps its still image."
			% (" (off by default on this machine)" if SettingsManager.render.is_weak_machine() else ""))
		BootTrace.step("menu stage off: still image")
		return
	# The splash first, over the menu: its buttons appear with the stage, not before it.
	_splash(true)
	add_to_group(BUILDING_GROUP)
	BootTrace.step("menu stage: asking the tile service")
	_probe = TileServiceProbe.new()
	_probe.start(PLANET_NAME)


func _exit_tree() -> void:
	if _probe != null:
		_probe.wait()
	if _pending_task != -1:
		PerfTasks.wait(_pending_task, "menu_stage")
		_pending_task = -1
	_session.end()


## The 3D stage is up (not the still-image fallback).
func is_live() -> bool:
	return _live


func _process(delta: float) -> void:
	if _probe != null and _probe.is_done():
		_probe.wait()  # a finished pool task must still be waited for, or it leaks (and exit crashes)
		var reachable : bool = _probe.ok
		_probe = null
		_progress(0.1)
		BootTrace.step("menu stage: tile service %s" % ("reachable" if reachable else "UNREACHABLE: still image"))
		if reachable:
			_build_then_release()
		else:
			remove_from_group(BUILDING_GROUP)
			_splash(false)
			print("[MenuStage] terrain tile service unreachable: the menu keeps its still image.")
	if _live and _resnap_left > 0.0:
		_resnap_tick += delta
		if _resnap_tick >= 1.0:
			_resnap_left -= _resnap_tick
			_resnap_tick = 0.0
			_outpost.resnap()


## Glide to a menu screen's viewpoint of the set.
func go_to(key: StringName) -> void:
	if not _live or not is_instance_valid(_rig):
		return
	var station : StageStation = _outpost.station(key)
	# A settings tab without its own viewpoint shares the Settings one.
	if station == null and String(key).begins_with("settings_"):
		station = _outpost.station(&"settings")
	if station != null:
		_rig.glide_to_view(station.transform)


## The hour of day on the stage (0..24).
func hour() -> float:
	return _hour


func set_hour(value: float) -> void:
	_hour = value
	if _live:
		StageClock.set_hour(_planet, _anchor, value)


## Build the stage, then let the warm-up start (BUILDING_GROUP), whether the stage came up or not.
func _build_then_release() -> void:
	await _build()
	remove_from_group(BUILDING_GROUP)


func _build() -> void:
	# Let the splash paint before the planet's set-up holds the main thread for a few seconds.
	for i in 2:
		await get_tree().process_frame
		if not is_inside_tree():
			return  # left while the splash painted (the game was entered, or closed)
	# Read from the disk on worker threads, and the planet's slowest data made there too, while the splash
	# goes on painting: all this held the main thread ~12 s in a single frame (2-3 s of loading, 4.4 s of
	# roads and biomes in Planet._ready), and Windows closed the game as "not responding" (2026-11-16).
	var scene : PackedScene = await _load_world()
	if scene == null:
		return  # left meanwhile, or the scene did not load (already said)
	BootTrace.step("menu stage: instancing the world")
	var world : Node3D = scene.instantiate()
	# Before the world enters the tree: the planet places itself for the (frozen) clock in its _ready.
	_session.begin(world)
	# Hidden until its pipelines are compiled (_pipelines_compiled): drawn at once, its first frame waited for
	# every one of them, 17 s on a cold cache (the first launch, a new driver).
	world.visible = false
	BootTrace.step("menu stage: world in the tree (planet set up on the main thread)")
	add_child(world)
	BootTrace.step("menu stage: waiting for the first ground")
	_progress(0.5)  # the planet's set-up held the main thread: the bar jumps rather than crawls
	_planet = world.get_node(NodePath(PLANET_NODE))
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
		if not is_inside_tree():
			return  # left while waiting for the ground: the session is already handed back
		waited += get_process_delta_time()
		# The ground: chunks built out of those asked for, or the time left, whichever is further.
		var terrain : PlanetTerrain = _planet.planet_terrain
		var built : float = 0.0
		if terrain != null and terrain.desired_chunk_count() > 0:
			built = float(terrain.active_chunk_count()) / terrain.desired_chunk_count()
			BootTrace.step("menu stage: ground %d/%d chunks" % [terrain.active_chunk_count(),
				terrain.desired_chunk_count()], true)
		_progress(0.5 + 0.5 * maxf(built, waited / READY_TIMEOUT_S))
	_outpost.start(_planet.planet_data.radius, _drawn_ground)
	BootTrace.step("menu stage: ground %s, waiting for its pipelines" % ("ready" if ground_ready[0] else "late"))
	await _pipelines_compiled()
	if not is_inside_tree():
		return
	world.visible = true
	_resnap_left = RESNAP_FOR_S
	_menu.set_stage_mode(true)
	_splash(false)
	print("[MenuStage] live on %s after %.1f s (ground %s)" % [PLANET_NAME, waited,
		"ready" if ground_ready[0] else "late"])
	BootTrace.step("menu stage: live")
	if AUTO_ENTER_ARG in OS.get_cmdline_user_args():
		print("[MenuStage] %s: entering the universe" % AUTO_ENTER_ARG)
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
		return
	if VillageBench.wanted():
		_menu.hide()  # the bench measures the scene, not the menu over it
		for layer: Node in _menu.find_children("*", "CanvasLayer", true, false):
			(layer as CanvasLayer).visible = false
		var bench := VillageBench.new()
		bench.setup(self, _planet, _rig, _anchor, _drawn_ground)
		add_child(bench)


## The world scene, loaded on a worker thread, then its planet's data prepared on another
## (PlanetData.prepare_off_main_thread): frames go on meanwhile. Null when left before the end, or when
## the scene does not load.
## One loading thread, without sub-threads: with them, on 2 or 4 worker threads, the load hung for good on
## the mannequin's or the bust's materials (a worker waiting for shaders ran another sub-load, which waited
## for a lock held below it -- the warm-up's deadlock of 2026-11-19), and the start stayed on its splash
## (2026-11-27, reproduced with threading/worker_pool/max_threads=2 or 4; 8 and more went through).
func _load_world() -> PackedScene:
	BootTrace.step("menu stage: loading the world (%s)" % WORLD_SCENE)
	if ResourceLoader.load_threaded_request(WORLD_SCENE, "", false) != OK:
		push_error("[MenuStage] cannot load %s" % WORLD_SCENE)
		return null
	var done : Array = []
	while ResourceLoader.load_threaded_get_status(WORLD_SCENE, done) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		_progress(0.1 + 0.25 * float(done[0]) if not done.is_empty() else 0.1)
		if not done.is_empty():
			BootTrace.step("menu stage: loading the world, %d %%" % roundi(100.0 * float(done[0])), true)
		await get_tree().process_frame
		if not is_inside_tree():
			return null  # the load goes on; the resource cache keeps what it made
	var scene := ResourceLoader.load_threaded_get(WORLD_SCENE) as PackedScene
	if scene == null:
		push_error("[MenuStage] %s did not load" % WORLD_SCENE)
		return null
	var data : PlanetData = planet_data_of(scene)
	BootTrace.step("menu stage: world loaded, preparing the planet's data on a worker")
	if data != null:
		_pending_task = PerfTasks.add_task("menu_stage:planet_data", data.prepare_off_main_thread, true, "MenuStage planet data")
		while not WorkerThreadPool.is_task_completed(_pending_task):
			await get_tree().process_frame
			if not is_inside_tree():
				return null  # _exit_tree waits for the task
		PerfTasks.wait(_pending_task, "menu_stage")
		_pending_task = -1
	BootTrace.step("menu stage: planet data ready")
	_progress(0.4)
	return scene


## Waits until the pipelines Godot has queued so far have been compiled. Godot queues a surface's pipelines
## on worker threads as soon as a render meets it, hidden or not, and a frame that DRAWS the surface blocks the
## main thread until they are done, behind every compilation queued before them. A high-priority marker task
## queued after them runs once all of those have started (the queue is first in, first out): the frames go on
## meanwhile instead of freezing.
func _pipelines_compiled() -> void:
	await RenderingServer.frame_post_draw  # the render that met the newest surfaces
	_pending_task = PerfTasks.add_task("menu_stage:pipelines", func() -> void: pass, true, "MenuStage pipelines")
	while not WorkerThreadPool.is_task_completed(_pending_task):
		await get_tree().process_frame
		if not is_inside_tree():
			return  # _exit_tree waits for the task
	PerfTasks.wait(_pending_task, "menu_stage")
	_pending_task = -1


## The PlanetData the stage's planet will carry, read from the scenes without instancing them: a sub-resource
## that is not local to its scene, so it is the very one the planet gets on instancing. Null if not found.
static func planet_data_of(world: PackedScene) -> PlanetData:
	var state : SceneState = world.get_state()
	for i in state.get_node_count():
		if state.get_node_name(i) != PLANET_NODE:
			continue
		var found : PlanetData = _planet_data_property(state, i)
		var inner : PackedScene = state.get_node_instance(i)
		if found == null and inner != null:
			found = _planet_data_property(inner.get_state(), 0)
		return found
	return null


static func _planet_data_property(state: SceneState, node: int) -> PlanetData:
	for p in state.get_node_property_count(node):
		if state.get_node_property_name(node, p) == &"planet_data":
			return state.get_node_property_value(node, p) as PlanetData
	return null


## The ground as the chunks DRAW it, distance from the centre along `dir`: measured on the chunk's
## own mesh (DrawnGround) — a height query is what the chunk was built from, and the outpost's plateau
## is drawn 20 cm off its relief query (the figures' ankles were cut, then their shins). Before the
## chunk is drawn, the query: the carved relief plus the biome's own, which no ground query adds.
func _drawn_ground(dir: Vector3) -> float:
	if _ground == null:
		_ground = DrawnGround.new(_planet, _planet.planet_data.radius,
				_planet.planet_terrain.drawn_mesh_at, _queried_ground)
	return _ground.dist(dir)


func _queried_ground(dir: Vector3) -> float:
	var data : PlanetData = _planet.planet_data
	return data.carved_surface_dist(dir) + BiomeRelief.offset(dir, data.radius, data.biome_at(dir))


## The menu's light: the sun just risen (MENU_SUN_ELEVATION_DEG), whatever the season. Solved on
## the first call; later calls set the hour found, one placement instead of a hundred.
func _sunrise() -> void:
	if _sunrise_hour < 0.0:
		var found : float = StageClock.set_sun_elevation(_planet, _anchor, MENU_SUN_ELEVATION_DEG)
		_sunrise_hour = found if found >= 0.0 else 12.0
	set_hour(_sunrise_hour)


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
