class_name VolcanoPlume
extends Node3D
## The smoke and the thrown stones of one active volcano, client side, in the volcano's own frame: the
## vent at the origin, +Y on the local up. Eruption timing derives from the shared clock and profiles;
## the local weather bends the smoke. No per-puff network state is needed.
##
## Costly on the GPU, so only the MAX_FULL volcanoes nearest the camera are drawn, within MAX_VIEW_M.
## Never Godot's volumetric fog: it does not work this far from the origin (see DustLights). The shader
## works in local metres and receives the camera position computed here in double precision.

const SHADER_DIR := "res://assets/_universe/environment/terrain/volcano/"
const MAX_VIEW_M := 300000.0
const MAX_FULL := 3
## Stones are not thrown for an eye farther than this (m): a stone is a pixel by then.
const STONES_VIEW_M := 40000.0
const BOX_CENTER := Vector3(0.0, 7000.0, 0.0)
const BOX_SIZE := Vector3(110000.0, 22000.0, 110000.0)
## Eye height (m) over the ground under which the camera is taken for a player a stone can hit.
const ON_FOOT_M := 6.0
const EYE_M := 1.7
const REFERENCE_HEIGHT_M := 2500.0

## R&D only: added to the shared clock, to jump to a moment of the volcano's life.
static var debug_time_shift := 0.0
## Stones that have hit the player since the start.
static var hits_total := 0
static var _alive: Array[VolcanoPlume] = []
static var _billow: NoiseTexture3D = null

var model := VolcanoPlumeModel.new()
var stones: VolcanoStoneField
var volcano: VolcanoRelief.Volcano
var data: PlanetData
var _mat := ShaderMaterial.new()
var _box: MeshInstance3D
var _origin := Vector3.ZERO
var _up := Vector3.UP
var _ex := Vector3.RIGHT
var _ez := Vector3.BACK
var _a := PackedVector4Array()
var _b := PackedVector4Array()
var _c := PackedVector4Array()
var _dist := INF
var _frame_no := 0
var _relight := VolcanoPlumeModel.COUNT
var _on_foot := false
var _foot_check_at := 0.0
var _planet: Planet
var _wind_tick := 0.0
var _model_elapsed := 0.0
var _light_elapsed := 0.0
var _last_eye := Vector3.INF
var _last_forward := Vector3.INF
var _last_fov := -1.0
## WorkerThreadPool task running model.update (-1: none). The model is the worker's until it is joined;
## the main thread reads the snapshot below (~10 ms per update during a 40 min eruption on a Xeon E5).
var _task := -1
var _snap_a := PackedVector4Array()
var _snap_b := PackedVector4Array()
var _snap_c := PackedVector4Array()
var _snap_active := PackedInt32Array()


## [param centre]: the vent in the planet's frame (the parent's).
static func create(planet_data: PlanetData, v: VolcanoRelief.Volcano, centre: Vector3) -> VolcanoPlume:
	var plume := VolcanoPlume.new()
	plume.name = "Plume"
	plume.data = planet_data
	plume.volcano = v
	plume._origin = centre
	plume._up = v.c.normalized()
	var ref := Vector3.UP if absf(plume._up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	plume._ex = plume._up.cross(ref).normalized()
	plume._ez = plume._ex.cross(plume._up).normalized()
	plume.basis = Basis(plume._ex, plume._up, plume._ez)
	plume.model.profile = VolcanoActivityProfile.for_planet(planet_data.planet_name)
	plume.model.configure_appearance(v.seed, VolcanoFeatures.key_of(v), plume.model.profile.appearance_variation)
	# A cinder cone smokes less high than a stratovolcano, from a smaller mouth, and throws lower.
	var scale_h := clampf(v.h / REFERENCE_HEIGHT_M, 0.12, 1.4)
	plume.model.ceiling_m *= scale_h
	plume.model.umbrella_m *= scale_h
	plume.model.vent_radius = maxf(v.rc, 40.0)
	plume.model.slowdown_m *= scale_h
	plume.model.rise_speed *= sqrt(scale_h)
	plume.model.phase = float(v.seed) * 97.0
	plume.model.volcano_key = VolcanoFeatures.key_of(v)
	# The export gives no seed (all 0): the key, the same on every client, gives each volcano its own schedule.
	plume.model.volcano_seed = v.seed ^ int(plume.model.volcano_key.hash())
	plume.model.dormant = v.activity == "dormant"
	return plume


## The shared clock, in real seconds: the smoke does not follow a time-scaled or shifted sky.
static func clock() -> float:
	return (Globals.sim_time() - Globals.debug_time_offset) / Globals.time_scale + debug_time_shift


## The drawn volcano closest to the camera, for the tools.
static func nearest() -> VolcanoPlume:
	var best: VolcanoPlume = null
	for plume in _alive:
		if best == null or plume._dist < best._dist:
			best = plume
	return best


func _ready() -> void:
	_alive.append(self)
	_planet = SurfaceProbe.planet_of(self)
	_update_wind(clock())
	_a.resize(VolcanoPlumeModel.COUNT)
	_b.resize(VolcanoPlumeModel.COUNT)
	_c.resize(VolcanoPlumeModel.COUNT)
	_mat.shader = load(SHADER_DIR + "plume.gdshader")
	_mat.set_shader_parameter("billow_tex", _billow_texture())
	_mat.set_shader_parameter("box_center", BOX_CENTER)
	_mat.set_shader_parameter("sigma", model.sigma)
	_mat.set_shader_parameter("ash_dark", Vector3(0.075, 0.075, 0.08) * model.ash_brightness)
	_mat.set_shader_parameter("ash_light", Vector3(0.31, 0.30, 0.295) * model.ash_brightness)
	_mat.set_shader_parameter("ash_warm", Vector3(0.30, 0.22, 0.16) * model.ash_brightness)
	_mat.set_shader_parameter("cloud_tint", Vector3(0.55, 0.55, 0.57) * model.ash_brightness)
	var box := BoxMesh.new()
	box.size = BOX_SIZE
	_box = MeshInstance3D.new()
	_box.name = "Smoke"
	_box.mesh = box
	_box.material_override = _mat
	_box.position = BOX_CENTER
	_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_box.extra_cull_margin = 16384.0
	add_child(_box)
	stones = VolcanoStoneField.new(model, _relief)
	stones.rebuild_on_jump = false
	var scale_h := clampf(volcano.h / REFERENCE_HEIGHT_M, 0.12, 1.4)
	stones.speed_scale = sqrt(scale_h)
	stones.throw_rate = scale_h
	stones.player_hit.connect(_on_player_hit)
	add_child(stones)


func _exit_tree() -> void:
	_alive.erase(self)
	_join_model(true)


## Joins the model's worker update when it is done (or now with [param wait]), then snapshots its puffs for
## the main thread. True when a new snapshot was taken.
func _join_model(wait: bool) -> bool:
	if _task < 0 or (not wait and not WorkerThreadPool.is_task_completed(_task)):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	# Copy on write: the next worker update writes its own buffers, these stay as they are.
	_snap_a = model.a
	_snap_b = model.b
	_snap_c = model.c
	_snap_active = model.active_indices.duplicate()
	return true


static func _billow_texture() -> NoiseTexture3D:
	if _billow == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		noise.frequency = 0.05
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		noise.fractal_octaves = 3
		noise.fractal_gain = 0.5
		_billow = NoiseTexture3D.new()
		_billow.width = 96
		_billow.height = 96
		_billow.depth = 96
		_billow.seamless = true
		_billow.invert = true
		_billow.normalize = true
		_billow.noise = noise
	return _billow


## The ground height in this node's frame at (x, z) of its tangent plane. Reads the same heights the
## terrain is built from: the client has no terrain collision to ask.
func _relief(x: float, z: float) -> float:
	var at := _origin + _ex * x + _ez * z
	var dir := at.normalized()
	var ground := dir * (data.radius + data.sample_height_for_direction(dir))
	return (ground - _origin).dot(_up)


func _process(delta: float) -> void:
	var fresh := _join_model(false)
	_wind_tick -= delta
	if _wind_tick <= 0.0 and _task < 0:  # the wind history is the model's: never while a worker updates it
		_wind_tick = 0.5
		_update_wind(clock())
	var viewport := get_viewport()
	var cam: Camera3D = viewport.get_camera_3d() if viewport != null else null
	if cam == null:
		stones.suspend()
		return
	var eye := to_local(cam.global_position)
	_dist = eye.length()
	var rank := 0
	for plume in _alive:
		if plume != self and plume._dist < _dist:
			rank += 1
	var drawn := _dist < MAX_VIEW_M and rank < MAX_FULL
	if not drawn:
		_box.hide()
	stones.visible = drawn and _dist < STONES_VIEW_M
	if not stones.visible:
		stones.suspend()
	if not drawn:
		_model_elapsed = 1.0
		return
	var t := clock()
	_frame_no += 1
	_model_elapsed += delta
	_light_elapsed += delta
	# Actual time budgets, independent of monitor refresh/FPS. Sleeping volcanoes still wake at 5 Hz.
	var interval := 1.0 / 30.0 if _dist < 20000.0 else (1.0 / 15.0 if _dist < 80000.0 else 1.0 / 8.0)
	if _snap_active.is_empty() and model.activity(t) <= 0.0:
		interval = 0.2
	if (_model_elapsed >= interval or _relight > 12) and _task < 0:
		if _light_elapsed >= 0.1 or _relight > 12:
			_light()
			_light_elapsed = 0.0
		# Puffs and their lighting on a worker; drawn from the next frame that finds it done.
		_task = WorkerThreadPool.add_task(model.update.bind(t, _relight), false, "volcano plume")
		_relight = 12
		_model_elapsed = fmod(_model_elapsed, interval)
	var changed := fresh
	if changed:
		_update_smoke_bounds()
	var fwd: Vector3 = global_basis.inverse() * -cam.global_basis.z
	if changed or cam.fov != _last_fov or not eye.is_equal_approx(_last_eye) or not fwd.is_equal_approx(_last_forward):
		var shown := _compact(eye, fwd, cam.fov)
		_box.visible = shown > 0
		if shown > 0:
			_mat.set_shader_parameter("puff_a", _a)
			_mat.set_shader_parameter("puff_b", _b)
			_mat.set_shader_parameter("puff_c", _c)
			_mat.set_shader_parameter("puff_count", shown)
		_last_eye = eye
		_last_forward = fwd
		_last_fov = cam.fov
	_mat.set_shader_parameter("cam_local", eye)
	_mat.set_shader_parameter("sim_time", fmod(t, 50.0))
	var flicker := 0.8 + 0.2 * sin(fmod(t, 1000.0) * 9.0) * sin(fmod(t, 1000.0) * 3.7)
	_mat.set_shader_parameter("glow", clampf(model.eruption_activity(t), 0.0, 1.3) * flicker)
	if stones.visible:
		_foot_check_at -= delta
		if not stones.has_live_stones(t):
			_on_foot = false
			_foot_check_at = 0.0
		elif _foot_check_at <= 0.0:
			_foot_check_at = 0.2
			_on_foot = eye.y - _relief(eye.x, eye.z) < ON_FOOT_M
		stones.update(t, eye, eye + Vector3.DOWN * EYE_M, _on_foot)


## Follow the actual smoke envelope so longer tails and taller plumes are never cut by the old box.
func _update_smoke_bounds() -> void:
	var low := Vector3.ZERO
	var high := Vector3.ZERO
	for i in _snap_active:
		if _snap_b[i].x <= 0.03:
			continue
		var puff := _snap_a[i]
		var centre := Vector3(puff.x, puff.y, puff.z)
		var radius := Vector3.ONE * puff.w
		low = low.min(centre - radius)
		high = high.max(centre + radius)
	# Quantization avoids rebuilding the simple box mesh for every small movement.
	low = (low / 2048.0).floor() * 2048.0 - Vector3.ONE * 512.0
	high = (high / 2048.0).ceil() * 2048.0 + Vector3.ONE * 512.0
	var box := _box.mesh as BoxMesh
	var size := high - low
	var centre := (high + low) * 0.5
	if not box.size.is_equal_approx(size):
		box.size = size
	if not _box.position.is_equal_approx(centre):
		_box.position = centre
		_mat.set_shader_parameter("box_center", centre)


func _update_wind(t: float) -> void:
	var local_wind := Vector3.ZERO
	if is_instance_valid(_planet):
		local_wind = global_basis.inverse() * _planet.wind_world_at(global_position)
	var multiplier := model.profile.wind_multiplier if model.profile != null else 1.6
	model.sample_wind(t, Vector2(local_wind.x, local_wind.z) * multiplier)
	if stones != null:
		stones.trail_mat.set_shader_parameter("wind", Vector3(model.wind.x, 0.0, model.wind.y) * 0.25)


## Sun and sky, in this frame: the star's real direction, and how much of it reaches here by now.
func _light() -> void:
	var to_star := Vector3.UP
	var scene: Node = NetworkOrchestrator.universe_scene
	var star: Node3D = scene.get_node_or_null("Star") as Node3D if scene != null else null
	if star != null:
		to_star = (star.global_position - global_position).normalized()
		to_star = (global_basis.inverse() * to_star).normalized()
	model.sun_dir = to_star
	var day := smoothstep(-0.1, 0.18, to_star.y)
	var low := 1.0 - smoothstep(0.0, 0.35, to_star.y)
	var sun := Vector3(1.9, 1.8, 1.65).lerp(Vector3(2.1, 1.25, 0.7), low) * day
	var sky := Vector3(0.6, 0.66, 0.75) * lerpf(0.1, 1.0, day)
	stones.trail_mat.set_shader_parameter("smoke_color", Vector3(0.26, 0.25, 0.245) * lerpf(0.05, 1.0, day))
	_mat.set_shader_parameter("sun_dir", to_star)
	_mat.set_shader_parameter("sun_color", sun)
	_mat.set_shader_parameter("sky_color", sky)
	_mat.set_shader_parameter("ground_color", Vector3(0.3, 0.27, 0.25) * lerpf(0.05, 1.0, day))
	_mat.set_shader_parameter("haze_color", sky * 0.85)
	_mat.set_shader_parameter("lava_fill", lerpf(3.5, 0.7, day))


## Only the puffs that can touch the screen go to the shader: every pixel tests each one it receives.
func _compact(eye: Vector3, fwd: Vector3, fov_deg: float) -> int:
	# Half-angle of the corner of the screen, with a margin for the turn of the next frame.
	var half := deg_to_rad(fov_deg) * 0.5 * 1.95 + 0.05
	var n := 0
	for i in _snap_active:
		if _snap_b[i].x <= 0.03:
			continue
		var s: Vector4 = _snap_a[i]
		var to := Vector3(s.x, s.y, s.z) - eye
		var d := to.length()
		if d > s.w and acos(clampf(fwd.dot(to / d), -1.0, 1.0)) > half + asin(s.w / d):
			continue
		_a[n] = s
		_b[n] = _snap_b[i]
		_c[n] = _snap_c[i]
		n += 1
	return n


func _on_player_hit(impact_speed: float, radius: float) -> void:
	hits_total += 1
	print("[Volcano] stone of %.1f m hit the player at %.0f m/s" % [radius, impact_speed])
