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

@export_group("Dark adaptation")
## Adapt the exposure to the scene. OFF by default, after measurement: this project runs with
## `use_physical_light_units` disabled, which leaves CameraAttributes' ISO sensitivities without the
## meaning that would turn a wide min/max range into a wide gain. The measured gain is a few, against
## the 1e5 a moonlit night needs — so it cannot do the job it was switched on for, and MoonLights'
## explicit gain does it instead.
##
## Worse, the two together fight: a fixed gain is what MAKES the night darker than the day, and an
## auto-exposure's whole purpose is to bring them back to the same brightness. Kept as a switch
## because a mild adaptation is pleasant on its own, but it is no longer load-bearing.
@export var dark_adaptation: bool = false
## Sensitivity bounds, ISO-like. The ceiling is DERIVED, not picked: a ground lit by Korax at 10
## degrees of elevation returns 7.9e-7 in engine units, and bringing that to a dim but readable 0.15
## needs a sensitivity of 1.9e7. An earlier cap of 1e6 was below what Korax needs even at the ZENITH
## (2.4e6), which is why a rising moon seemed to light nothing until it was high: the eye was already
## against the stop and could not open further as the moon sank. Godot's own defaults (0 to 800) span
## a factor of eight, which is a camera's range, not an eye's.
@export var adaptation_min_sensitivity: float = 20.0
@export var adaptation_max_sensitivity: float = 2.0e7
## How fast it opens and closes. Real dark adaptation takes minutes; this is deliberately quicker,
## because a player who turns around should not wait for the world to appear.
@export var adaptation_speed: float = 0.5
## Brightness of the starfield. Pushed from here so it can be tuned live in the remote inspector,
## because it is the only number in this lot with no physical anchor: dark adaptation normalises the
## frame, and at night the stars ARE the frame. 0.05 restores the look the night had before adaptation
## was switched on, whose eye opened about twenty times less far.
@export var star_brightness: float = 1.0

@export_group("Debug")
## Look at the lowlands without going there. OFF in play; a development tool, kept because it is the
## only way to inspect them at all.
##
## Sandbox's one city stands 5634 m up, above the corundum veil, so the permanent storm the lore
## describes cannot be seen from the single place anyone plays — and the acceptance figures written
## for it (a milky dome, 7 km of visibility, a star swallowed near the horizon) were unverifiable
## until this existed.
##
## It raises the haze CEILING by the player's own altitude, every frame, leaving its thickness and its
## coefficients alone, and lowers the observer by the same amount for the light. What ends up overhead
## is then exactly what a lowlander has: 3500 m of veil, an optical depth of 1.904 — the figure that
## pins the planet's published 0.32 albedo.
##
## It fakes the OBSERVER, never the planet: measured from the ground the column is no longer the
## calibrated one. A way to look, and nothing more.
@export var debug_pretend_lowlands: bool = false

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
	player.get_world_3d().camera_attributes = _build_camera_attributes()


## The eye. Set on the WORLD alongside the Environment, so every camera in it adapts together —
## a mirror that kept a fixed exposure while the main view adapted would read as a lit screen at night.
func _build_camera_attributes() -> CameraAttributesPractical:
	var attributes := CameraAttributesPractical.new()
	attributes.auto_exposure_enabled = dark_adaptation
	attributes.auto_exposure_min_sensitivity = adaptation_min_sensitivity
	attributes.auto_exposure_max_sensitivity = adaptation_max_sensitivity
	attributes.auto_exposure_speed = adaptation_speed
	return attributes


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
	var profile: AtmosphereProfile = current_profile()
	_show_star_mesh(profile == null)
	if profile == null:
		_push_airless(star_direction)
		return
	_push_profile(profile, star_direction)


## Hand the star's disc to whichever of the two things that draw it is right here.
##
## scenes/_universe/environment/space/star.tscn is an additive quad with `fog_disabled` that writes no
## depth, so the aerial perspective pass skips its pixels as empty sky and it shone through Sandbox's
## dust storm at full strength — where the real transmittance is 6e-12. Inside an atmosphere the sky
## shader already draws that disc, at the body's real angular diameter and dimmed by the transmittance
## it has just integrated, so the mesh is redundant AND the wrong one of the two. In space the sky
## draws none (there is no irradiance to spread), and the mesh comes back.
##
## Only visibility is touched. Everything else reads the node's POSITION — PlayerSunLight for the star
## direction, PlanetBody and PlanetTerrain for their own lighting — and that is untouched.
func _show_star_mesh(shown: bool) -> void:
	if not is_instance_valid(sun):
		return
	var star := sun.get_star()
	if star == null or star.visible == shown:
		return
	star.visible = shown


## Leave the star as we found it. Without this, quitting to the menu from a planet would leave the
## mesh hidden for whatever comes next.
func _exit_tree() -> void:
	_show_star_mesh(true)


## The body the player is currently standing on, or null in open space. Resolved through the gravity
## area, and resolved HERE ONLY: PlayerSunLight used to walk the same chain for its own purposes, and
## two resolvers can disagree about which planet you are on. Everything atmospheric asks this node.
func current_body() -> Planet:
	var area: Node = player.get_current_gravity_parent()
	if area == null or area.get_parent() == null:
		return null
	var body: Node = area.get_parent().get_parent()
	if not (body is Planet):
		return null
	return body as Planet


## The atmosphere of that body, or null when it is open space or an airless body.
func current_profile() -> AtmosphereProfile:
	var body := current_body()
	if body == null or body.planet_data == null:
		return null
	var profile: AtmosphereProfile = body.planet_data.atmosphere_profile
	if profile == null or not profile.has_atmosphere():
		return null
	return profile


## Height of the player above the body's REFERENCE SPHERE, which is the altitude the density profiles
## are written against — not the height above the terrain, which on a plateau differs by kilometres.
func altitude_above_sphere() -> float:
	var body := current_body()
	if body == null or body.planet_data == null:
		return 0.0
	return (player.global_position - body.global_position).length() - body.planet_data.radius


## How far to raise the haze ceiling, in metres. See debug_pretend_lowlands.
func _haze_lift() -> float:
	if not debug_pretend_lowlands:
		return 0.0
	return maxf(0.0, altitude_above_sphere())


## Fraction of the light arriving from [param sin_elevation] above the local horizon, per channel,
## that survives the air. White in open space, black when the body itself is in the way.
##
## Serves the star and the moons alike — it is the same air — and it is what makes a source lose most
## of its glare near the horizon instead of switching off across an arbitrary softness band.
func transmittance_at(sin_elevation: float) -> Color:
	var profile := current_profile()
	if profile == null:
		return Color.WHITE
	# The debug lift has to reach the LIGHT too, or the veil rises over your head while the star keeps
	# shining at full plateau strength. Raising the ceiling for the shader and lowering the observer
	# for the integral both mean the same thing: 3500 m of corundum overhead.
	return profile.transmittance_to_star(altitude_above_sphere() - _haze_lift(), sin_elevation)


## Vector from the camera to the centre of the body the profile describes, or ZERO when it cannot be
## resolved. Subtracted HERE, in float64: world positions reach ~3e10 and the shader works in 32-bit
## floats, where that magnitude quantises to hundreds of metres. The shader therefore never sees an
## absolute position, only this small offset.
func _planet_center_relative() -> Vector3:
	var body := current_body()
	if body == null:
		return Vector3.ZERO
	return body.global_position - player.camera.global_position


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
		"haze_top": profile.haze_top + _haze_lift(),
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
	_sky_material.set_shader_parameter("star_brightness", star_brightness)


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
	_sky_material.set_shader_parameter("star_brightness", star_brightness)


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
