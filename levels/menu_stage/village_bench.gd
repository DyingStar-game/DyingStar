class_name VillageBench
extends Node
## A repeatable measure of the client where the game is heaviest: the mining village (252 homes, its
## depots, garage, lamps) set on the menu stage's Tarsis 3, offline, and the camera on a fixed path --
## a turn in a street, a flyover, a turn inside a home -- by day, then by night. Each window is boiled
## down by BenchmarkStats (mean, percentiles, slowest 1 %, worst frame, GPU and render CPU, draws);
## the report lands in user://benchmarks/village_bench_<stamp>.txt and the game quits.
##
## Launched with `--village-bench` (after `--` on the command line, or anywhere): the stage builds as
## usual, then hands over to this instead of the menu. The same path, the same window and the same
## settings every run: two runs differ by the change between them, not by where the camera looked.
##
## `--bench-hide=shell,lights,...` takes a family out of the village before each window (HIDE), so a run
## with it against one without says what that family costs. `--bench-set=wind_dust:0,ssil:0` turns
## graphics options for the run only (RenderSettings.set_transient: nothing is saved).

const ARG := "--village-bench"
const HIDE_ARG := "--bench-hide="
const SET_ARG := "--bench-set="
## A quick A/B: the day only, the street and the flyover.
const QUICK_ARG := "--bench-quick"
## A screenshot of each window's first pose, beside the report (to compare what a change shows).
const SHOTS_ARG := "--bench-shots"
## The sun's height (degrees) for the day windows instead of LIGHTS' (a dawn: --bench-sun=5).
const SUN_ARG := "--bench-sun="
## Pictures only, from fixed poses (VIEWS), then quit: to show what a model change looks like up close.
const VIEWS_ARG := "--bench-views"
## Name -> [eye, look], in the village's frame: over the roofs of tarsis_4-1001, and its home 0-0-0's ceiling.
const VIEWS := {
	"roofs": [Vector3(-1.0, 12.0, -3.0), Vector3(-3.5, 7.0, 6.0)],
	"roof_close": [Vector3(-0.5, 9.2, 0.5), Vector3(-3.5, 7.6, 3.5)],
	"ceiling": [Vector3(-3.0, 1.4, 1.3), Vector3(-4.2, 2.6, 1.0)],
}
## The model's own roof, for --bench-hide=oldroof (the lighter one is the scene's override).
const ORIGINAL_MODEL := "res://assets/_universe/structures/buildings/habitat_container.glb"
## The families --bench-hide can take out.
const HIDE := ["shell", "interiors", "walkways", "lights", "shadows", "casters", "fringe", "labels", "props",
		"village", "outpost", "terrain", "aerial", "skyrefl", "sunshadow", "ssao", "ssil", "ssr", "glow",
		"hexq0", "hexq1", "terraincast", "aeriallut",
		"interiorlights", "arealights", "spotlights", "omnilights", "shelllod", "oldroof"]
const VILLAGE := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
## Where the village stands from the stage's anchor (m, degrees from north): clear of the outpost.
const DISTANCE_M := 350.0
const BEARING_DEG := 90.0
## The window every run is measured in: borderless, this size, no vsync, no frame cap.
const WINDOW_SIZE := Vector2i(1920, 1080)
## Seconds after placing the village before anything is measured: the pads level the ground, the
## tiles under them arrive, the homes near the camera furnish.
const SETTLE_S := 10.0
## Each window: seconds to settle at its first pose, then seconds measured along its path.
const SHOT_SETTLE_S := 2.0
const SHOT_S := 8.0
## The sun's height (degrees) for each light.
const LIGHTS := [["day", 35.0], ["night", -25.0]]
## A frame longer than this (ms) is listed with what came with it.
const SPIKE_MS := 40.0

## The shots, in the village's frame (its origin is building tarsis_4-1001's corner): where the eye is
## and what it looks at, as a function of t in 0..1 along the shot.
const STREET_EYE := Vector3(-4.0, 1.7, -3.0)
const FLY_CENTRE := Vector3(5.0, 0.0, 12.0)
const FLY_RADIUS_M := 90.0
const FLY_HEIGHT_M := 60.0
## Inside apartment 0-0-0 of tarsis_4-1001 (x -6.1..0, z 0..2.6), at eye height over its floor.
const HOME_EYE := Vector3(-3.0, 1.6, 1.3)

## The report's columns: one window a line.
const ROW_HEAD := "%-14s %7s %7s %7s %7s %7s %7s %7s %5s %7s %7s %7s %7s %6s %7s %9s %6s %6s %5s"
const ROW := "%-14s %7.1f %7.2f %7.2f %7.2f %7.2f %7.1f %7.1f %5d %7.2f %7.2f %7.2f %7.2f %6d %7d %9d %6d %6d %5d"

var _stage: MenuStage
var _planet: Planet
var _rig: StageRig
var _village: Node3D
var _results: Array = []
var _stats: BenchmarkStats
var _last_usec: int = 0
var _hidden: PackedStringArray = []
var _set: Dictionary = {}


## True when this run is a bench.
static func wanted() -> bool:
	return ARG in OS.get_cmdline_user_args() or ARG in OS.get_cmdline_args()


## The families asked off on the command line.
static func hidden_families() -> PackedStringArray:
	var out: PackedStringArray = []
	for family: String in _arg_list(HIDE_ARG):
		assert(family in HIDE, "unknown family %s" % family)
		out.append(family)
	return out


## The graphics options asked for on the command line: {key: value}.
static func set_options() -> Dictionary:
	var out: Dictionary = {}
	for pair: String in _arg_list(SET_ARG):
		var kv: PackedStringArray = pair.split(":")
		out[kv[0]] = str_to_var(kv[1]) if kv.size() > 1 else true
	return out


static func _arg_list(prefix: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for arg: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with(prefix):
			out.append_array(arg.trim_prefix(prefix).split(",", false))
	return out


## Set up by the stage once it is live: its planet, its camera rig, where its clock is read and the
## ground as the chunks draw it.
func setup(stage: MenuStage, planet: Planet, rig: StageRig, anchor_local: Vector3, ground: Callable) -> void:
	_stage = stage
	_planet = planet
	_rig = rig
	var frame := SurfaceFrame.new(anchor_local, planet.planet_data.radius, ground)
	var dir: Vector3 = frame.dir_at(DISTANCE_M, BEARING_DEG)
	_village = (load(VILLAGE) as PackedScene).instantiate() as Node3D
	_village.transform = Transform3D(frame.basis_at(dir, 0.0), frame.point(DISTANCE_M, BEARING_DEG))
	for piece: Node in _village.get_children():
		if piece is SpawnBuilding:
			(piece as SpawnBuilding).build_on_ready = true  # no server here to send its apartments
		ReplicaDress.prepare(piece, true)
	planet.add_child(_village)


func _ready() -> void:
	ClientPerf.set_process(false)  # its census would land in the windows
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_size(WINDOW_SIZE)
	DisplayServer.window_set_position(Vector2i.ZERO)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	# The lamps' shadows as the game gives them: the local player carries this budget (PlayerClient).
	add_child(LampShadowBudget.new())
	_hidden = hidden_families()
	_set = set_options()
	if not _set.is_empty():
		SettingsManager.render.set_transient(_set)
	_run.call_deferred()


func _run() -> void:
	_frame_at(STREET_EYE, STREET_EYE + Vector3.LEFT)
	await _wait(SETTLE_S)
	if VIEWS_ARG in OS.get_cmdline_user_args():
		await _views()
		get_tree().quit()
		return
	var quick: bool = not _arg_list(QUICK_ARG).is_empty() or QUICK_ARG in OS.get_cmdline_user_args()
	var sun: PackedStringArray = _arg_list(SUN_ARG)
	for light: Array in (LIGHTS.slice(0, 1) if quick else LIGHTS):
		var elevation: float = float(sun[0]) if not sun.is_empty() and light[0] == "day" else float(light[1])
		StageClock.set_sun_elevation(_planet, _village.position, elevation)
		await _shot("%s street" % light[0], _street)
		await _shot("%s flyover" % light[0], _flyover)
		if not quick:
			await _shot("%s home" % light[0], _home)
	_write_report()
	get_tree().quit()


## A picture from each of VIEWS, in user://benchmarks/shots/view_<name>.png.
func _views() -> void:
	StageClock.set_sun_elevation(_planet, _village.position, float(LIGHTS[0][1]))
	_hide_families()
	DirAccess.make_dir_recursive_absolute("user://benchmarks/shots")
	for view: String in VIEWS:
		_frame_at(VIEWS[view][0], VIEWS[view][1])
		await _wait(SHOT_SETTLE_S)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://benchmarks/shots/view_%s.png" % view)


## A turn on the spot in the street between the rows.
func _street(t: float) -> Array:
	var a: float = TAU * t
	return [STREET_EYE, STREET_EYE + Vector3(cos(a), -0.05, sin(a))]


## A circle over the village, looking at its middle.
func _flyover(t: float) -> Array:
	var a: float = TAU * t
	var eye: Vector3 = FLY_CENTRE + Vector3(cos(a) * FLY_RADIUS_M, FLY_HEIGHT_M, sin(a) * FLY_RADIUS_M)
	return [eye, FLY_CENTRE]


## A turn inside a home.
func _home(t: float) -> Array:
	var a: float = TAU * t
	return [HOME_EYE, HOME_EYE + Vector3(cos(a), -0.1, sin(a))]


## One window: settle at the shot's first pose, then measure every frame along it.
func _shot(label: String, path: Callable) -> void:
	var pose: Array = path.call(0.0)
	_frame_at(pose[0], pose[1])
	await _wait(SHOT_SETTLE_S)
	_hide_families()
	if SHOTS_ARG in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("user://benchmarks/shots")
		get_viewport().get_texture().get_image().save_png("user://benchmarks/shots/%s.png" % label.replace(" ", "_"))
	_stats = BenchmarkStats.new()
	var pipe_at: int = PerfMath.pipeline_total()
	var elapsed: float = 0.0
	var spikes: PackedStringArray = []
	var pipe_before: PackedInt32Array = _pipes()
	var nodes_before: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_last_usec = Time.get_ticks_usec()
	while elapsed < SHOT_S:
		await get_tree().process_frame
		var now: int = Time.get_ticks_usec()
		var frame_ms: float = float(now - _last_usec) / 1000.0
		_last_usec = now
		elapsed += frame_ms / 1000.0
		# A slow frame, with what came with it: shaders compiled, nodes added or freed, where the time went.
		var pipe_now: PackedInt32Array = _pipes()
		var nodes_now: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		if frame_ms > SPIKE_MS:
			var pipe_new: PackedStringArray = []
			for i in pipe_now.size():
				pipe_new.append(str(pipe_now[i] - pipe_before[i]))
			spikes.append("%.2fs %.0fms pipe+%s nodes%+d gpu %.1f proc %.1f phys %.1f setup %.1f" % [elapsed,
					frame_ms, "/".join(pipe_new), nodes_now - nodes_before,
					RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()),
					Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
					Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
					RenderingServer.get_frame_setup_time_cpu()])
		pipe_before = pipe_now
		nodes_before = nodes_now
		pose = path.call(clampf(elapsed / SHOT_S, 0.0, 1.0))
		_frame_at(pose[0], pose[1])
		_sample(frame_ms)
	var window: Dictionary = _stats.summary()
	window.merge({
		"draws": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"primitives": RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"vram_mib": BenchmarkFacts.vram_mib(),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"pipe": PerfMath.pipeline_total() - pipe_at,
	}, true)
	window["spikes"] = spikes
	_results.append([label, window])
	print("[VillageBench] %s: %.1f fps, p99 %.1f ms, worst %.1f ms, gpu %.2f ms" % [label, window["fps"],
			window["p99"], window["max"], window["gpu"]])


## The pipelines compiled so far, by source: canvas / mesh / surface / draw / specialization.
static func _pipes() -> PackedInt32Array:
	var out: PackedInt32Array = []
	for monitor: int in PerfMath.PIPE_MONITORS:
		out.append(int(Performance.get_monitor(monitor)))
	return out


func _sample(frame_ms: float) -> void:
	var root: RID = get_viewport().get_viewport_rid()
	_stats.add_frame(frame_ms, {
		"gpu": RenderingServer.viewport_get_measured_render_time_gpu(root),
		"cpu": RenderingServer.viewport_get_measured_render_time_cpu(root),
		"setup": RenderingServer.get_frame_setup_time_cpu(),
		"proc": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"phys": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	})


## The rig at [param eye] looking at [param look], both in the village's frame.
func _frame_at(eye: Vector3, look: Vector3) -> void:
	_rig.frame(_village.transform * eye, _village.transform * look)


## The world around the village: the whole village, the stage's outpost, the terrain, the sky's passes,
## the sun's shadow, the screen effects of the Environment.
func _hide_world() -> void:
	_village.visible = not "village" in _hidden
	if "outpost" in _hidden:
		(_planet.get_node("Outpost") as Node3D).visible = false
	if "terrain" in _hidden and _planet.planet_terrain != null:
		_planet.planet_terrain.visible = false
	if "terraincast" in _hidden and _planet.planet_terrain != null:
		for chunk: Node in _planet.planet_terrain.find_children("*", "GeometryInstance3D", true, false):
			(chunk as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for quality: int in 2:
		if "hexq%d" % quality in _hidden:
			RenderingServer.global_shader_parameter_set("planet_hex_quality", quality)
	var atmosphere := _rig.get_node_or_null("AtmosphereRenderer") as AtmosphereRenderer
	if "aerial" in _hidden and atmosphere != null:
		atmosphere.set_aerial_enabled(false)
	if "skyrefl" in _hidden and atmosphere != null:
		atmosphere.set_sky_reflection_enabled(false)
	if "aeriallut" in _hidden and atmosphere != null:
		atmosphere.set_aerial_lut_enabled(false)
	if "sunshadow" in _hidden and _rig.has_node("PlayerSunLight"):
		(_rig.get_node("PlayerSunLight") as Light3D).shadow_enabled = false
	var env: Environment = get_viewport().world_3d.environment if get_viewport().world_3d != null else null
	if env != null:
		env.ssao_enabled = env.ssao_enabled and not "ssao" in _hidden
		env.ssil_enabled = env.ssil_enabled and not "ssil" in _hidden
		env.ssr_enabled = env.ssr_enabled and not "ssr" in _hidden
		env.glow_enabled = env.glow_enabled and not "glow" in _hidden


## Take the families asked off out of the village (again each window: the homes near the camera
## furnish as it moves).
func _hide_families() -> void:
	if _hidden.is_empty():
		return
	_hide_world()
	for piece: Node in _village.get_children():
		var building := piece as SpawnBuilding
		if building == null:
			if "props" in _hidden and piece is Node3D:
				(piece as Node3D).visible = false
			continue
		for apartment: Node in building.get_node("MultiMeshInstance3D").get_children():
			if "shell" in _hidden and apartment.has_node("habitat_container"):
				(apartment.get_node("habitat_container") as Node3D).visible = false
			if "interiors" in _hidden and apartment.has_node("Interior"):
				apartment.get_node("Interior").free()
		if "interiors" in _hidden and building.has_node("InteriorStreamer"):
			building.get_node("InteriorStreamer").set_process(false)
		if "walkways" in _hidden and building.has_node("Walkways"):
			(building.get_node("Walkways") as Node3D).visible = false
	if "oldroof" in _hidden:
		var model: Node = (load(ORIGINAL_MODEL) as PackedScene).instantiate()
		var original: Mesh = (model.find_child("roof", true, false) as MeshInstance3D).mesh
		model.free()
		for roof: Node in _village.find_children("roof", "MeshInstance3D", true, false):
			(roof as MeshInstance3D).mesh = original
	if "shelllod" in _hidden:
		for lod: Node in _village.find_children("ShellLod", "", true, false):
			for path: String in ShellLod.DETAILED:
				var part := lod.get_parent().get_node_or_null(path) as GeometryInstance3D
				if part != null:
					part.visibility_range_end = 0.0
			lod.queue_free()
	for node: Node in _village.find_children("*", "Light3D", true, false):
		if "lights" in _hidden:
			(node as Light3D).visible = false
		if "interiorlights" in _hidden and _in_interior(node):
			(node as Light3D).visible = false
		if "arealights" in _hidden and node.get_class() == "AreaLight3D":
			(node as Light3D).visible = false
		if "spotlights" in _hidden and node is SpotLight3D:
			(node as Light3D).visible = false
		if "omnilights" in _hidden and node is OmniLight3D and not _in_interior(node):
			(node as Light3D).visible = false
		if "shadows" in _hidden:
			(node as Light3D).shadow_enabled = false
	for node: Node in _village.find_children("*", "GeometryInstance3D", true, false):
		var geometry := node as GeometryInstance3D
		if "casters" in _hidden:
			geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if "fringe" in _hidden and GroundLook.is_ours(geometry.material_overlay):
			geometry.material_overlay = null
		if "labels" in _hidden and geometry is Label3D:
			geometry.visible = false


## True when [param node] belongs to a home's furniture (an apartment's streamed Interior).
static func _in_interior(node: Node) -> bool:
	while node != null:
		if node.name == &"Interior":
			return true
		node = node.get_parent()
	return false


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _write_report() -> void:
	var lines: PackedStringArray = []
	var version: Dictionary = BenchmarkFacts.game_version()
	lines.append("VillageBench %s" % Time.get_datetime_string_from_system())
	lines.append("version: %s" % str(version))
	lines.append("adapter: %s (%s) | window %s | %s" % [RenderingServer.get_video_adapter_name(),
			RenderingServer.get_video_adapter_vendor(), str(DisplayServer.window_get_size()),
			ProjectSettings.get_setting("rendering/renderer/rendering_method")])
	lines.append("hidden: %s | set: %s" % [",".join(_hidden) if not _hidden.is_empty() else "none", str(_set)])
	lines.append(ROW_HEAD % ["window", "fps", "mean", "p50", "p95", "p99", "low1", "max", "hit", "gpu",
			"gpu95", "cpu", "setup", "draws", "objects", "prims", "vram", "nodes", "pipe"])
	for entry: Array in _results:
		var w: Dictionary = entry[1]
		lines.append(ROW % [entry[0], w["fps"], w["mean"], w["p50"], w["p95"], w["p99"], w["low1"], w["max"],
				w["hitches"], w["gpu"], w["gpu_p95"], w["cpu"], w["setup"], w["draws"], w["objects"],
				w["primitives"], w["vram_mib"], w["nodes"], w["pipe"]])
	for entry: Array in _results:
		for spike: String in entry[1]["spikes"]:
			lines.append("  spike %-14s %s" % [entry[0], spike])
	var text: String = "\n".join(lines)
	print(text)
	DirAccess.make_dir_recursive_absolute("user://benchmarks")
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "user://benchmarks/village_bench_%s.txt" % stamp
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text + "\n")
	print("[VillageBench] report: %s" % ProjectSettings.globalize_path(path))
