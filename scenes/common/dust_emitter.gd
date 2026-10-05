class_name DustEmitter
extends RefCounted

## Dust thrown up from the ground by one actor — a walking player, a rolling vehicle. Client only: the
## game server draws nothing, and every client raises the dust of everyone it sees from the replicated
## motion, the same way it plays their footsteps.
##
## ONE GPUParticles3D per actor, fed by emit_particle(): a draw call per actor, however many puffs.
##
## The particles live in the GROUND's frame, never the actor's and never the world's:
##   - not the world's: at ~1e11 m a world-space particle position reaches the GPU in float32 and the
##     dust would shake by metres. In local coordinates it stays exact;
##   - not the actor's: dust thrown by a wheel stays where it was thrown while the truck drives on —
##     that is what draws the trail, for free;
##   - the ground's (the actor's parent, usually the planet): the cloud turns with the planet.
## The emitter is an ANCHOR placed under the actor's parent, its +Y on the local up. When the actor has
## gone ANCHOR_RADIUS_M away, or changed parent, a fresh anchor is laid where it is and the old one is
## left to finish its puffs, then freed — moving it would drag the cloud along.
##
## Physics, from the body the actor stands on: in air the dust is braked and settles slowly and swells
## as it mixes (SurfaceDust's Air group); on an airless body it flies on ballistic arcs under the real
## gravity and does not swell.

const SHADER_PATH := "res://assets/_universe/vfx/ground_dust.gdshader"
const PROCESS_SHADER_PATH := "res://assets/_universe/vfx/ground_dust_process.gdshader"
## How far (m) the actor may go from its anchor before a new one is laid. Float32 stays sub-millimetre
## over that distance, and the local up barely turns (0.06° on a 1000 km planet).
const ANCHOR_RADIUS_M: float = 1000.0
## No dust is raised further than this (m) from the camera: a puff that size is a pixel away.
const CULL_DISTANCE_M: float = 90.0
## How often (s) the ground colour and the body's air are read again: both change over metres, not frames.
const GROUND_REFRESH_S: float = 0.5

static var _shader: Shader = null
static var _process_shader: Shader = null

var _actor: Node3D = null
var _dust: SurfaceDust = null
var _capacity: int = 32
var _lifetime: float = 2.0
var _particles: GPUParticles3D = null
var _ground_color: Color = Color(0.55, 0.48, 0.4)
var _airless: bool = false
var _gravity: float = 9.8
var _ground_read_at: float = -INF  # seconds (ticks); -INF = read at the next puff


## `capacity`: particles alive at once (debit × lifetime must fit, or the oldest are recycled early).
## `lifetime`: seconds a particle lives, in air (airless it is shortened, see _configure).
func _init(actor: Node3D, dust: SurfaceDust, capacity: int = 32, lifetime: float = 2.0) -> void:
	_actor = actor
	_dust = dust
	_capacity = capacity
	_lifetime = lifetime


## False where nothing is drawn: the editor and the game server.
static func enabled() -> bool:
	return not Engine.is_editor_hint() and not OS.has_feature("dedicated_server")


## Raise `count` particles of dust at `global_pos`, on ground of `family`. The patch lies flat on the
## local ground, the anchor's XZ plane (its +Y is the actor's up).
##   `strength`: 0..1+, how hard the ground is disturbed (scales the number of grains and their size);
##   `velocity`: m/s, world-oriented, the throw of the dust (a wheel throws it back, a foot barely);
##   `spread`: m, radius of the patch the grains come from;
##   `size`: m, diameter of one grain cloud at birth.
func puff(global_pos: Vector3, family: StringName, strength: float, velocity: Vector3,
		count: int = 2, spread: float = 0.2, size: float = 0.5) -> void:
	if not enabled() or _dust == null or _actor == null or not _actor.is_inside_tree():
		return
	var amount: float = _dust.amount(family) * strength
	if amount <= 0.01 or not _near_camera(global_pos):
		return
	if not _ensure_anchor():
		return
	_refresh_ground(global_pos)
	var color: Color = _dust.color(family, _ground_color)
	color.a = clampf(amount, 0.0, 1.0)
	var to_local: Basis = _particles.global_basis.inverse()
	var local_pos: Vector3 = _particles.to_local(global_pos)
	var local_vel: Vector3 = to_local * velocity
	var n: int = maxi(1, roundi(count * clampf(amount, 0.25, 1.5)))
	for i in n:
		var offset := Vector3(randf_range(-spread, spread), 0.0, randf_range(-spread, spread))
		var grain_size: float = size * randf_range(0.7, 1.3) * lerpf(0.6, 1.0, clampf(amount, 0.0, 1.0))
		var jitter := Vector3(randf_range(-0.3, 0.3), randf_range(0.0, 0.4), randf_range(-0.3, 0.3))
		var xform := Transform3D(Basis.from_scale(Vector3.ONE * grain_size), local_pos + offset)
		_particles.emit_particle(xform, local_vel + jitter, color, Color(),
				GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_ROTATION_SCALE
				| GPUParticles3D.EMIT_FLAG_VELOCITY | GPUParticles3D.EMIT_FLAG_COLOR)


## True when the anchor in use is still good for an actor at `local_offset` from it, in `parent`.
## Static and pure so the rule is testable without a scene.
static func anchor_holds(anchor_parent: Node, parent: Node, local_offset: Vector3) -> bool:
	return anchor_parent == parent and local_offset.length() <= ANCHOR_RADIUS_M


## Free the anchor now. Called by the owner when it goes away for good.
func release() -> void:
	if is_instance_valid(_particles):
		_particles.queue_free()
	_particles = null


## The owner dropped us without release(): free the anchor anyway, or it would outlive the actor in the
## parent's frame. Inline on purpose: a RefCounted being deleted can no longer call its own methods.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_particles):
		_particles.queue_free()


func _near_camera(global_pos: Vector3) -> bool:
	var viewport := _actor.get_viewport()
	var camera: Camera3D = viewport.get_camera_3d() if viewport != null else null
	if camera == null:
		return true
	return camera.global_position.distance_squared_to(global_pos) <= CULL_DISTANCE_M * CULL_DISTANCE_M


## Make sure an anchor fits the actor where it is now; lay a new one if not. False when there is no
## ground frame to lay it in.
func _ensure_anchor() -> bool:
	var frame := _actor.get_parent() as Node3D
	if frame == null:
		return false
	if is_instance_valid(_particles):
		if anchor_holds(_particles.get_parent(), frame, _particles.to_local(_actor.global_position)):
			return true
		_retire(_particles)
	_particles = _make_particles()
	frame.add_child(_particles)
	# +Y on the actor's up, at the actor: gravity is then just -Y in the process shader.
	var up: Vector3 = _actor.global_basis.y.normalized()
	var ref: Vector3 = Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x: Vector3 = up.cross(ref).normalized()
	_particles.global_transform = Transform3D(Basis(x, up, x.cross(up)), _actor.global_position)
	_ground_read_at = -INF  # a new place: read the ground and the air again
	return true


## Let a superseded anchor finish its puffs, then free it.
func _retire(old: GPUParticles3D) -> void:
	var tree := old.get_tree()
	if tree == null:
		old.queue_free()
		return
	tree.create_timer(old.lifetime * 2.0).timeout.connect(func() -> void:
		if is_instance_valid(old):
			old.queue_free())


func _make_particles() -> GPUParticles3D:
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
		_process_shader = load(PROCESS_SHADER_PATH) as Shader
	var p := GPUParticles3D.new()
	p.name = "GroundDust"
	# Manual emission only. Measured in Godot 4.7: emit_particle() emits NOTHING with amount_ratio = 0,
	# and emitting = true would add the engine's own stream on top of ours.
	p.emitting = false
	p.amount = _capacity
	p.amount_ratio = 1.0
	p.lifetime = _lifetime
	p.local_coords = true
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var reach := ANCHOR_RADIUS_M + 50.0
	p.visibility_aabb = AABB(Vector3.ONE * -reach, Vector3.ONE * reach * 2.0)
	var process := ShaderMaterial.new()
	process.shader = _process_shader
	p.process_material = process
	var quad := QuadMesh.new()
	var look := ShaderMaterial.new()
	look.shader = _shader
	quad.material = look
	p.draw_pass_1 = quad
	return p


## Read the ground colour and the air of the body under the actor, at most every GROUND_REFRESH_S.
func _refresh_ground(global_pos: Vector3) -> void:
	var now: float = Time.get_ticks_msec() * 0.001
	if now - _ground_read_at < GROUND_REFRESH_S:
		return
	_ground_read_at = now
	_ground_color = _dust.fallback_color
	var planet: Planet = SurfaceProbe.planet_of(_actor)
	if planet != null and planet.planet_data != null:
		var data: PlanetData = planet.planet_data
		var radial: Vector3 = planet.to_local(global_pos)
		if not radial.is_zero_approx():
			_ground_color = GroundLook.at(data, radial.normalized(), _dust.fallback_color).color
		_airless = data.atmosphere_profile == null
		_gravity = data.surface_gravity
	_configure()


## Push the air of the current body into the process shader.
func _configure() -> void:
	if not is_instance_valid(_particles):
		return
	var process := _particles.process_material as ShaderMaterial
	if process == null:
		return
	if _airless:
		process.set_shader_parameter(&"settle", _gravity)
		process.set_shader_parameter(&"drag", 0.0)
		process.set_shader_parameter(&"growth", 1.0)
	else:
		process.set_shader_parameter(&"settle", _dust.air_settle)
		process.set_shader_parameter(&"drag", _dust.air_drag)
		process.set_shader_parameter(&"growth", _dust.air_growth)
