class_name AtmosphereRenderer
extends Node

## Client-only owner of everything the atmosphere DRAWS: the sky dome and the aerial perspective
## pass. PlayerSunLight used to do the light, the sky and the fog at once; it now keeps only the
## DirectionalLight, and this node takes the two others.
##
## It decides nothing about how the sky looks. It resolves which body the player is in, reads that
## body's AtmosphereProfile, and pushes its constants into the two shaders. Both consume the same
## atmosphere_common.gdshaderinc, so the dome and the limb cannot disagree.
##
## The geometry (star direction, stabilised up) is NOT recomputed here: it is read from
## PlayerSunLight, which already owns the hard-won astronomic-coordinate version of it.

## The owned player body this renderer follows (set by PlayerClient right after instancing).
var player: Node3D = null
## The sun whose star direction we reuse (set by PlayerClient; never recomputed here).
var sun: PlayerSunLight = null

## Trades quality for cost on the main view. Wired to the graphics settings later.
@export var view_steps: int = 32
@export var light_steps: int = 8
## Multiplies the physical-to-engine exposure derived below. 1.0 = the derived value; this is the
## ONE knob that is allowed to be turned by eye, and it may only scale, never tint.
@export var exposure_scale: float = 1.0

var _sky_material: ShaderMaterial = null
var _aerial_material: ShaderMaterial = null
var _aerial_quad: MeshInstance3D = null


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)  # the sky is a client-side visual; the headless server renders nothing
		return
	# Run AFTER PlayerSunLight (priority 100) so the star direction we read is this frame's, not the
	# previous one — otherwise the sky lags the light by a frame at sunrise and sunset.
	process_priority = 110
	_build_environment()
	_build_aerial_quad()


## The Environment lives on the WORLD, not on the player camera, so EVERY camera in this world gets
## the sky — including the vehicle mirror and reverse-cam SubViewports, which share get_world_3d()
## and own no Environment. One shared sky material, so all views stay in step; EYEDIR makes each of
## them render from its own angle.
func _build_environment() -> void:
	_sky_material = ShaderMaterial.new()
	_sky_material.shader = load("res://scenes/_universe/environment/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = _sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.glow_enabled = true
	# No volumetric fog any more: the aerial perspective pass IS the haze, computed from the same
	# coefficients as the sky. Keeping the old 0.002 fog on top would count the air twice, and it is
	# what the "visibility at ground level" figure of the model would be measured against.
	env.volumetric_fog_enabled = false
	player.get_world_3d().environment = env


## Full-screen pass for the air in front of geometry. A shader_type sky cannot draw it: it only
## paints where nothing was rendered, so it gives the dome and never the planet's limb.
##
## The quad rewrites its own vertices in clip space, so its transform is irrelevant — but Godot still
## culls it by its AABB, hence the cull margin. Parented to the camera so it follows the main view.
func _build_aerial_quad() -> void:
	if player.camera == null:
		return
	_aerial_material = ShaderMaterial.new()
	_aerial_material.shader = load("res://scenes/_universe/environment/aerial_perspective.gdshader")
	# Composite last, so the screen texture it reads already holds everything else.
	_aerial_material.render_priority = 100
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_aerial_quad = MeshInstance3D.new()
	_aerial_quad.name = "AerialPerspective"
	_aerial_quad.mesh = quad
	_aerial_quad.material_override = _aerial_material
	_aerial_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aerial_quad.extra_cull_margin = 16384.0
	_aerial_quad.layers = Globals.RENDER_MASK_LOCAL
	_aerial_quad.position = Vector3(0.0, 0.0, -1.0)
	player.camera.add_child(_aerial_quad)


func _process(_delta: float) -> void:
	if not is_instance_valid(player) or player.camera == null or not is_instance_valid(sun):
		return
	if _sky_material == null:
		return
	var star_direction: Vector3 = sun.star_direction
	if star_direction == Vector3.ZERO:
		return  # the sun has not found the star yet; leave last frame's sky rather than flash black
	var profile: AtmosphereProfile = _current_profile()
	if profile == null:
		_push_airless(star_direction)
		return
	_push_profile(profile, star_direction)


## The atmosphere of the body the player is currently in, or null in open space or on a body that
## carries none. Resolved through the gravity area the player is standing in, the same chain the sun
## uses, so light and sky can never end up describing two different planets.
func _current_profile() -> AtmosphereProfile:
	var area: Node = player.get_current_gravity_parent()
	if area == null or area.get_parent() == null:
		return null
	var body: Node = area.get_parent().get_parent()
	if not (body is Planet):
		return null
	var data: PlanetData = (body as Planet).planet_data
	if data == null or data.atmosphere_profile == null:
		return null
	if not data.atmosphere_profile.has_atmosphere():
		return null
	return data.atmosphere_profile


## Vector from the camera to the centre of the body the profile describes, or ZERO when it cannot be
## resolved. Subtracted HERE, in float64: world positions reach ~3e10 and the shader works in 32-bit
## floats, where that magnitude quantises to hundreds of metres. The shader therefore never sees an
## absolute position, only this small offset.
func _planet_center_relative() -> Vector3:
	var area: Node = player.get_current_gravity_parent()
	if area == null or area.get_parent() == null:
		return Vector3.ZERO
	var body: Node = area.get_parent().get_parent()
	if not (body is Node3D):
		return Vector3.ZERO
	return (body as Node3D).global_position - player.camera.global_position


## Push one body's constants into both shaders. Every value comes from the profile; nothing is
## invented here.
func _push_profile(profile: AtmosphereProfile, star_direction: Vector3) -> void:
	var values := {
		"planet_center": _planet_center_relative(),
		"planet_radius": profile.planet_radius,
		"atmosphere_top": profile.atmosphere_top,
		"rayleigh_beta": profile.rayleigh_beta,
		"rayleigh_scale_height": profile.rayleigh_scale_height,
		"mie_beta": profile.mie_beta,
		"mie_g": profile.mie_g,
		"mie_albedo": profile.mie_albedo,
		"haze_top": profile.haze_top,
		"haze_falloff": maxf(profile.haze_falloff, 1.0),
		"mie_scale_height": maxf(profile.mie_scale_height, 1.0),
		"absorption_beta": profile.absorption_beta,
		"absorption_center": profile.absorption_center,
		"absorption_width": maxf(profile.absorption_width, 1.0),
		"to_star": star_direction,
		"star_irradiance": profile.star_irradiance,
		"star_color": Vector3(profile.star_color.r, profile.star_color.g, profile.star_color.b),
		"view_steps": view_steps,
		"light_steps": light_steps,
		"sky_exposure": _sky_exposure(profile),
	}
	_apply(values)
	_sky_material.set_shader_parameter("star_angular_diameter", profile.star_angular_diameter)


## Open space, or an airless body: zero the coefficients so scatter() returns nothing and its
## transmittance stays 1. The stars then burn at full strength on black, which is exactly right —
## no altitude fudge factor is involved, unlike the shader this replaces.
func _push_airless(star_direction: Vector3) -> void:
	_apply({
		"planet_center": Vector3.ZERO,
		"planet_radius": 0.0,
		"atmosphere_top": 0.0,
		"rayleigh_beta": Vector3.ZERO,
		"mie_beta": Vector3.ZERO,
		"absorption_beta": Vector3.ZERO,
		"to_star": star_direction,
		"star_irradiance": 0.0,
	})


func _apply(values: Dictionary) -> void:
	for key in values:
		_sky_material.set_shader_parameter(key, values[key])
		if _aerial_material != null:
			_aerial_material.set_shader_parameter(key, values[key])


## Bridge between physical radiance (W/m2/sr) and the engine's arbitrary light units.
##
## The engine's own sun delivers `sun_energy` for this body's `star_irradiance`, and Godot's Lambert
## term carries no 1/PI, so a scattered radiance L lands consistently at L * PI * sun_energy /
## star_irradiance. Deriving it rather than picking a number is what keeps the sky and the sunlit
## ground in the same relationship on every body, whatever its star.
func _sky_exposure(profile: AtmosphereProfile) -> float:
	if profile.star_irradiance <= 0.0:
		return 0.0
	return PI * sun.sun_energy / profile.star_irradiance * exposure_scale
