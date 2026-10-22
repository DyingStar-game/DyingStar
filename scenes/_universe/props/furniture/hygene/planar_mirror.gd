class_name PlanarMirror
extends Node3D

## A real mirror: the room and the people in it, ourselves included. A camera stands where ours is
## reflected through the glass, its view cut to the glass's frame (a frustum projection whose near plane
## is the glass: nothing behind the mirror gets in), and renders into a texture laid on the glass, turned
## left for right.
##
## This node IS the glass: centred on it, +Z out of it, [member size] wide and high. A reflection is a
## second render of the scene, so ONE mirror reflects at a time: the nearest one on screen that our
## camera stands in front of, within [member max_distance_m]. Its viewport is made when it starts and
## freed when it stops; the others show the model's own glass. That render skips the costly effects of
## the world's environment (light_environment). Our own body is seen through its MirrorDouble (first
## person hides our head). Client only: nothing on the server.

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_back;
uniform sampler2D reflection : source_color, filter_linear;
void fragment() {
	ALBEDO = texture(reflection, vec2(1.0 - UV.x, UV.y)).rgb;
}
"""

## How deep (m) the mirror shows, from the glass: the room before it -- a container is 6.1 m long.
## Farther, out of its door, the sky. The far plane is set past the glass by this much (the camera stands
## behind the glass, as far as our eye stands before it).
const DEPTH_M := 7.0
## A nearer mirror takes the reflection over only when nearer by this much (m): standing between two,
## they do not swap every frame.
const SWAP_MARGIN_M := 0.5

## Width and height (m) of the glass.
@export var size: Vector2 = Vector2(0.99, 0.59)
## Height (px) of the reflection's texture; its width follows the glass's proportions.
@export_range(64, 2048, 16) var resolution: int = 512
## Farther than this (m) from the glass, the mirror does not reflect.
@export_range(1.0, 50.0, 0.5) var max_distance_m: float = 6.0

## The mirror reflecting now, if any: the double of our body is shown while there is one.
static var _current: PlanarMirror = null
## The world environment the light one was made from, and the light one (light_environment).
static var _env_source: Environment = null
static var _env_light: Environment = null
## The mirror shader, compiled once for all of them.
static var _shared_shader: Shader = null

var _glass: MeshInstance3D
var _on_screen: VisibleOnScreenNotifier3D
var _viewport: SubViewport
var _camera: Camera3D
var _double: MirrorDouble
## How far our eye is from the glass, INF while this mirror may not reflect.
var _distance: float = INF


func _ready() -> void:
	if GameOrchestrator.is_server():
		set_process(false)
		return
	_on_screen = VisibleOnScreenNotifier3D.new()
	_on_screen.aabb = AABB(Vector3(-size.x * 0.5, -size.y * 0.5, -0.01), Vector3(size.x, size.y, 0.02))
	add_child(_on_screen)
	# Only a mirror on screen looks for the eye: 60 of them in the furnished homes around asked every frame.
	_on_screen.screen_entered.connect(set_process.bind(true))
	_on_screen.screen_exited.connect(_on_screen_exited)
	set_process(false)
	var quad := QuadMesh.new()
	quad.size = size
	_glass = MeshInstance3D.new()
	_glass.mesh = quad
	_glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glass.visible = false  # the model's own glass shows until this mirror reflects
	add_child(_glass)


func _exit_tree() -> void:
	if _current == self:
		_stop()


func _on_screen_exited() -> void:
	if _current == self:
		_stop()
	set_process(false)


func _process(_delta: float) -> void:
	var eye_camera: Camera3D = get_viewport().get_camera_3d()
	_distance = INF
	if eye_camera != null and is_visible_in_tree() and _on_screen.is_on_screen():
		_distance = reach(global_transform, eye_camera.global_position, max_distance_m)
	if _current == self:
		if _distance == INF:
			_stop()
	elif _distance < INF and (not is_instance_valid(_current) or _distance < _current._distance - SWAP_MARGIN_M):
		if is_instance_valid(_current):
			_current._stop()
		_start(eye_camera)
	if _current == self:
		_camera.global_transform = reflected_view(global_transform, eye_camera.global_position)
		var to_glass: Vector3 = global_position - _camera.global_position
		var near: float = to_glass.dot(-_camera.global_basis.z)
		_camera.set_frustum(size.y, Vector2(to_glass.dot(_camera.global_basis.x), to_glass.dot(_camera.global_basis.y)),
				near, near + DEPTH_M)


## How far [param eye] stands from the glass [param glass] (+Z out of it), or INF when it is behind it
## or farther than [param max_m]: not worth a reflection. Pure, for the tests.
static func reach(glass: Transform3D, eye: Vector3, max_m: float) -> float:
	var from_glass: Vector3 = eye - glass.origin
	var distance: float = from_glass.length()
	return distance if from_glass.dot(glass.basis.z.normalized()) > 0.05 and distance <= max_m else INF


## Where the mirror's camera stands for an eye at [param eye], before the glass [param glass] (+Z out
## of it): the eye's reflection through the glass's plane, looking straight into the glass (its -Z
## along the glass's +Z), upright like the glass. Pure, for the tests.
static func reflected_view(glass: Transform3D, eye: Vector3) -> Transform3D:
	var normal: Vector3 = glass.basis.z.normalized()
	var mirrored: Vector3 = eye - 2.0 * (eye - glass.origin).dot(normal) * normal
	var up: Vector3 = glass.basis.y.normalized()
	return Transform3D(Basis(-glass.basis.x.normalized(), up, -normal), mirrored)


## The world's environment without what costs most and shows least in a small mirror (ambient
## occlusion and light, screen-space reflections, glow, GI, volumetric fog): one copy, shared by every
## mirror, made again when the world's changes (the graphics options).
static func light_environment(world: Environment) -> Environment:
	if world == null:
		return null
	if world != _env_source or _env_light == null:
		_env_source = world
		_env_light = world.duplicate() as Environment
		_env_light.ssao_enabled = false
		_env_light.ssil_enabled = false
		_env_light.ssr_enabled = false
		_env_light.glow_enabled = false
		_env_light.sdfgi_enabled = false
		_env_light.volumetric_fog_enabled = false
	return _env_light


## The mirror reflecting now (null: none), for the tests and the double.
static func current() -> PlanarMirror:
	return _current if is_instance_valid(_current) else null


## Reflect: make the viewport and its camera, lay their picture on the glass.
func _start(eye_camera: Camera3D) -> void:
	_current = self
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(roundi(resolution * size.x / size.y), resolution)
	_viewport.positional_shadow_atlas_size = 0  # the lamps' shadows are not worth it in a mirror
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_FRUSTUM
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	# Everything but our own first-person body (headless): our double stands in for it.
	_camera.cull_mask = ~Globals.RENDER_MASK_OWN_BODY & 0xFFFFF
	_camera.environment = light_environment(
			eye_camera.environment if eye_camera.environment != null else get_world_3d().environment)
	_viewport.add_child(_camera)
	var material := ShaderMaterial.new()
	material.shader = _shader()
	material.set_shader_parameter(&"reflection", _viewport.get_texture())
	_glass.material_override = material
	_glass.visible = true
	if _double == null:
		_double = _local_double()
	if is_instance_valid(_double):
		_double.visible = true


## Stop reflecting: free the viewport, give the glass back to the model.
func _stop() -> void:
	if _current == self:
		_current = null
	if _glass != null:
		_glass.visible = false
		_glass.material_override = null
	if _viewport != null:
		_viewport.queue_free()
		_viewport = null
		_camera = null
	if is_instance_valid(_double):
		_double.visible = false


## The mirror shader, compiled once for all.
static func _shader() -> Shader:
	var shader: Shader = _shared_shader
	if shader == null:
		shader = Shader.new()
		shader.code = SHADER_CODE
		_shared_shader = shader
	return shader



## The double of the local player's body (whose camera is the current one).
func _local_double() -> MirrorDouble:
	var node: Node = get_viewport().get_camera_3d()
	while node != null and not (node is Player):
		node = node.get_parent()
	return MirrorDouble.of(node) if node != null else null
