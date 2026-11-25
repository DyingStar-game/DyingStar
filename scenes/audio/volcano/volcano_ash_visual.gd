extends Node3D
## CLIENT: the ash and lapilli one sees falling while the ash fall is heard (volcano_ash_fall.gd gives the
## smoothed level). One GPUParticles3D in a box around the camera, in the plume's frame (+Y up): the
## particles stay put in the world as the camera moves (ash_fall.gdshader), drift with the local wind,
## and are lit like everything else (sun, moons, the vent's light; no light of their own, so nothing at
## a black night). Hidden indoors (WeatherMasks), high above the ground and when no ash falls.
##
## No class_name: VolcanoSound preloads it by path.

const SHADER := "res://assets/_universe/environment/terrain/volcano/ash_fall.gdshader"
## The group WeatherMasks puts itself in.
const MASKS_GROUP := &"weather_masks"

## Particles at the densest fall; the ash level scales how many are alive (amount_ratio). Fine ash:
## many small flakes rather than a few big ones.
@export var flakes: int = 6000
## Size (m) of the box of falling ash around the camera: larger = deeper but sparser for the same count.
@export var box_m: Vector3 = Vector3(40.0, 30.0, 40.0)
## Size (m) of a flake of ash; the rare lapilli draw up to 1.4 times it.
@export var flake_m: float = 0.022
## Falling speed (m/s) of a mean flake; lapilli fall faster, fine ash slower.
@export var fall_m_s: float = 1.8
## Albedo of the ash: dark grey, lit by the scene's lights.
@export var ash_color: Color = Color(0.14, 0.13, 0.12)
## No falling ash for a camera higher than this (m) over the ground: from the air it is a haze, not flakes.
@export var max_height_m: float = 150.0

var _particles: GPUParticles3D
var _mat := ShaderMaterial.new()
var _last_eye := Vector3.INF
var _masks: Node = null
var _masks_at := 0.0


func _ready() -> void:
	name = "AshVisual"
	_mat.shader = load(SHADER)
	_mat.set_shader_parameter("box_size", box_m)
	_mat.set_shader_parameter("fall_speed", fall_m_s)
	var draw := StandardMaterial3D.new()
	draw.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	draw.billboard_keep_scale = true
	draw.albedo_color = ash_color
	draw.roughness = 1.0
	draw.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * flake_m
	quad.material = draw
	_particles = GPUParticles3D.new()
	_particles.amount = flakes
	# Every frame: cam_delta is one frame of camera motion.
	_particles.fixed_fps = 0
	_particles.lifetime = 8.0
	_particles.preprocess = 8.0
	_particles.local_coords = true
	_particles.process_material = _mat
	_particles.draw_pass_1 = quad
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.visibility_aabb = AABB(-box_m * 0.5, box_m)
	_particles.amount_ratio = 0.0
	add_child(_particles)
	visible = false


## Once a frame. [param eye]: the camera in the parent's (the plume's) frame; [param level]: smoothed ash
## level 0..1; [param height_m]: camera height over the ground; [param wind]: local wind (m/s, this frame).
func update(eye: Vector3, world_eye: Vector3, level: float, height_m: float, wind: Vector3) -> void:
	var shown := level > 0.01 and height_m < max_height_m and not _indoors(world_eye)
	if not shown:
		visible = false
		_last_eye = Vector3.INF
		return
	visible = true
	position = eye
	# The camera's own motion, taken back from the particles; a jump (teleport, new plume) moves nothing.
	var moved: Vector3 = eye - _last_eye if _last_eye.is_finite() else Vector3.ZERO
	if moved.length() > box_m.length():
		moved = Vector3.ZERO
	_last_eye = eye
	_mat.set_shader_parameter("cam_delta", moved)
	_mat.set_shader_parameter("wind", wind)
	_particles.amount_ratio = clampf(level, 0.0, 1.0)


func _indoors(world_eye: Vector3) -> bool:
	_masks_at -= get_process_delta_time()
	if not is_instance_valid(_masks) and _masks_at <= 0.0:
		_masks_at = 2.0
		_masks = get_tree().get_first_node_in_group(MASKS_GROUP)
	return is_instance_valid(_masks) and _masks.call("inside", world_eye)
