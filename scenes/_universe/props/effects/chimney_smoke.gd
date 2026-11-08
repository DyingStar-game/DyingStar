class_name ChimneySmoke
extends Node3D
## A chimney's smoke, never stopping: put this node at the chimney's mouth, +Y up. A small, light
## cousin of the volcano's plume (VolcanoPlume): a pool of puffs (ChimneySmokeModel) ray-marched by the
## same shader, bent by the local weather's wind.
##
## Drawn only when seen (ADR 0027): within view_range_m and in the camera's view, asked every
## ScreenVisibility.CHECK_S, and only the MAX_DRAWN chimneys nearest the camera. Nothing on the
## dedicated server.

const SHADER := preload("res://assets/_universe/environment/terrain/volcano/plume.gdshader")
## The most chimneys drawn at once, the nearest to the camera.
const MAX_DRAWN := 8
## Puffs are laid out this often (s) within NEAR_M, and half as often farther.
const UPDATE_S := 1.0 / 20.0
const NEAR_M := 120.0
## The wind is read this often (s), and eased toward over WIND_EASE_S.
const WIND_S := 1.0
const WIND_EASE_S := 3.0
const LIGHT_S := 0.5

## How far (m) the smoke can be seen from.
@export_range(50.0, 1000.0, 10.0, "suffix:m") var view_range_m := 400.0
## Radius of the chimney's mouth (m): the smoke leaves it this wide.
@export_range(0.1, 5.0, 0.05, "suffix:m") var mouth_radius := 0.6
## Speed of the smoke leaving the mouth (m/s): a forced furnace draught blows faster than a stove.
@export_range(0.5, 15.0, 0.1, "suffix:m/s") var rise_speed := 3.0
## Seconds a puff lives: longer is a taller, longer trail.
@export_range(3.0, 40.0, 0.5, "suffix:s") var life_s := 12.0
## Widening of the column (m of radius per m travelled).
@export_range(0.05, 0.6, 0.01) var spread := 0.22
## How thick the smoke is: 1 is a dense column, 0.3 a light wisp.
@export_range(0.1, 2.0, 0.05) var density := 1.0
## Colour of the smoke in full light: near white for steam and heating, grey for a furnace.
@export var color := Color(0.78, 0.78, 0.8)

static var _alive: Array[ChimneySmoke] = []

var model: ChimneySmokeModel
var _mat := ShaderMaterial.new()
var _box: MeshInstance3D
var _planet: Planet
var _dist := INF
var _seen := false
var _check_s := 0.0
var _update_s := 0.0
var _wind_s := 0.0
var _light_s := 0.0
var _wind_target := Vector2.ZERO


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return
	_alive.append(self)
	model = ChimneySmokeModel.new(VolcanoPlumeModel.COUNT)
	model.mouth_radius = mouth_radius
	model.rise_speed = rise_speed
	model.life_s = life_s
	model.spread = spread
	model.density = 1.0
	model.phase = randf() * life_s
	_planet = SurfaceProbe.planet_of(self)
	_check_s = randf() * ScreenVisibility.CHECK_S
	var tint := Vector3(color.r, color.g, color.b)
	_mat.shader = SHADER
	_mat.set_shader_parameter("billow_tex", VolcanoPlume._billow_texture())
	_mat.set_shader_parameter("sigma", 0.55 * density / mouth_radius)
	_mat.set_shader_parameter("min_step", maxf(mouth_radius * 0.3, 0.12))
	_mat.set_shader_parameter("max_steps", 80)
	_mat.set_shader_parameter("ground_fade_m", 20.0)
	_mat.set_shader_parameter("glow", 0.0)
	_mat.set_shader_parameter("noise_freq", 0.6)
	_mat.set_shader_parameter("ash_dark", tint * 0.5)
	_mat.set_shader_parameter("ash_light", tint)
	_mat.set_shader_parameter("ash_warm", tint * 0.9)
	_mat.set_shader_parameter("cloud_tint", tint)
	_box = MeshInstance3D.new()
	_box.name = "Smoke"
	_box.mesh = BoxMesh.new()
	_box.material_override = _mat
	_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_box.visible = false
	add_child(_box)


func _exit_tree() -> void:
	_alive.erase(self)


## Whether a chimney at [param dist] m, [param rank] chimneys being nearer, seen or not, is drawn.
static func drawn(dist: float, rank: int, seen: bool, range_m: float) -> bool:
	return seen and dist < range_m and rank < MAX_DRAWN


func _process(delta: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		_dist = INF
		_box.visible = false
		return
	_dist = global_position.distance_to(cam.global_position)
	_check_s -= delta
	if _check_s <= 0.0:
		_check_s = ScreenVisibility.CHECK_S
		_seen = ScreenVisibility.sees_box(cam, _world_box(), view_range_m)
	var rank := 0
	for other: ChimneySmoke in _alive:
		if other != self and other._dist < _dist:
			rank += 1
	if not drawn(_dist, rank, _seen, view_range_m):
		_box.visible = false
		return
	_follow_wind(delta)
	_light_s -= delta
	if _light_s <= 0.0 or not _box.visible:
		_light_s = LIGHT_S
		_light()
	_update_s -= delta
	if _update_s <= 0.0 or not _box.visible:
		_update_s = UPDATE_S if _dist < NEAR_M else UPDATE_S * 2.0
		_lay_out()
	_box.visible = model.count > 0
	_mat.set_shader_parameter("cam_local", to_local(cam.global_position))
	_mat.set_shader_parameter("sim_time", fmod(_clock(), 50.0))


func _clock() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _lay_out() -> void:
	model.update(_clock())
	var size := model.high - model.low
	var centre := (model.high + model.low) * 0.5
	(_box.mesh as BoxMesh).size = size
	_box.position = centre
	_mat.set_shader_parameter("box_center", centre)
	_mat.set_shader_parameter("puff_a", model.a)
	_mat.set_shader_parameter("puff_b", model.b)
	_mat.set_shader_parameter("puff_c", model.c)
	_mat.set_shader_parameter("puff_count", model.count)


## The world box the smoke can fill: the column the puffs reach, whatever the wind.
func _world_box() -> AABB:
	var reach := rise_speed * life_s * 0.5 + 6.0
	return AABB(global_position - Vector3.ONE * reach, Vector3.ONE * reach * 2.0)


func _follow_wind(delta: float) -> void:
	_wind_s -= delta
	if _wind_s <= 0.0:
		_wind_s = WIND_S
		var w := Vector3.ZERO
		if is_instance_valid(_planet):
			w = global_basis.inverse() * _planet.wind_world_at(global_position)
		_wind_target = Vector2(w.x, w.z)
	model.wind = model.wind.lerp(_wind_target, clampf(delta / WIND_EASE_S, 0.0, 1.0))


func _light() -> void:
	var light := VolcanoPlume.sky_light(self)
	var day: float = light["day"]
	var sky: Vector3 = light["sky"]
	_mat.set_shader_parameter("sun_dir", light["to_star"])
	_mat.set_shader_parameter("sun_color", light["sun"])
	_mat.set_shader_parameter("sky_color", sky)
	_mat.set_shader_parameter("ground_color", Vector3(0.3, 0.27, 0.25) * lerpf(0.05, 1.0, day))
	_mat.set_shader_parameter("haze_color", sky * 0.85)
