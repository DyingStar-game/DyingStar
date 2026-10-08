class_name AtmosphereLod
extends RefCounted
## How much of a body's air to draw, from how big it looks: its levels of detail. One per body with air,
## owned by its PlanetTerrain, on the client.
##
##   OWN   the player's own body: its air is the sky and the aerial perspective (AtmosphereRenderer).
##   SHELL its air spans a pixel or more: a shell as big as the top of its air draws the light scattered
##         along the rays that graze the body — its limb (atmosphere_shell.gdshader) — around DISC.
##   DISC  any other body with air: its disc is the light its whole column of air and ground send back
##         to space (far_air, in terrain_far_light.gdshaderinc: every ground).
##
## Two models, each where it holds, on the same constants (the body's AtmosphereProfile):
##   - the DISC is what planetary albedos are computed with, a two-stream column (Eddington): light that
##     enters the air comes back out after as many scatterings as it takes. Counting ONE scattering, as
##     the sky does, turned the disc of every thick atmosphere black — Sandbox's corundum veil from
##     0.79 to 0.05 at the centre of the disc, the gas giants (30 and 96 bar) dark red (2026-10-06) —
##     where light that is scattered and never absorbed must come back out: Sandbox's published albedo
##     is 0.32 over a 0.15 ground, its veil BRIGHTENS it. The column gives 0.40 to 0.46, red to blue
##     (column_albedo; a plane albedo, which runs above the Bond albedo the 0.32 is).
##   - the SHELL is single scattering (the sky's scatter()), right for the thin grazing paths of a limb.
## A closed formula, the disc costs the same at every size: no sample count to lower for small bodies.
##
## Measured on Tarsis' bodies, 1080 px tall at 75° (2026-10-06): the air of every body seen from another
## is under a pixel (Tarsis 3 from its moon P3_M1: 0.83 px, the most), so the DISC is what a player sees
## today; SHELL is for a bigger screen, a narrower view, a closer pass.

enum Level { NONE = -1, OWN = 0, SHELL = 1, DISC = 2 }

## The shell shows from this many pixels of air on screen, and goes below SHELL_OFF_PX: the gap keeps
## a body sitting on the threshold from flickering between the two.
const SHELL_ON_PX := 1.0
const SHELL_OFF_PX := 0.75
## Eddington's closure for a conservative column: gamma = 3 (1 - g) / 4 per unit of optical depth.
const EDDINGTON := 0.75
const GlobalsDefs := preload("res://scenes/globals/globals.gd")
const SHELL_SHADER := preload("res://scenes/_universe/environment/atmosphere_shell.gdshader")
## Facets of the shell sphere: its silhouette is the air's outer edge, a few pixels across at most.
const SHELL_RADIAL_SEGMENTS := 48
const SHELL_RINGS := 24
## Samples along a ray through the limb, and toward the star from each.
const SHELL_VIEW_STEPS := 16
const SHELL_LIGHT_STEPS := 4

var level: Level = Level.NONE
var _profile: AtmosphereProfile
var _shell: MeshInstance3D = null


## For a body of [param profile]; [param parent] (its PlanetTerrain, at the body's centre) carries the
## shell, and [param light_color] / [param light_energy] are the terrain's own star light, so the shell
## is lit exactly as the ground under it.
func _init(profile: AtmosphereProfile, parent: Node3D = null, light_color := Color.WHITE,
		light_energy := 2.0) -> void:
	_profile = profile
	if parent != null and has_air(profile):
		_shell = _make_shell(light_color, light_energy)
		parent.add_child(_shell)


## Does [param profile] describe air worth drawing.
static func has_air(profile: AtmosphereProfile) -> bool:
	return profile != null and profile.has_atmosphere() and profile.atmosphere_top > 0.0


## Vertical optical depth of [param profile]'s haze, per channel.
static func haze_depth(profile: AtmosphereProfile) -> Vector3:
	if profile.haze_top > 0.0:
		return profile.mie_beta * (profile.haze_top - profile.haze_bottom)  # the slab integrates to its thickness
	return profile.mie_beta * profile.mie_scale_height


## The column's scattering in Eddington's measure, gamma x tau per channel: the Rayleigh scattering at
## full weight (g = 0), the haze's scattered part weighted by its forward peak, (1 - g).
static func column_gamma_tau(profile: AtmosphereProfile) -> Vector3:
	var rayleigh := profile.rayleigh_beta * profile.rayleigh_scale_height
	var haze := haze_depth(profile) * profile.mie_albedo * (1.0 - profile.mie_g)
	return (rayleigh + haze) * EDDINGTON


## The column's absorption, vertical optical depth per channel: its absorbing band (a tent, whose
## integral is its half-width) and what the haze absorbs.
static func column_absorption(profile: AtmosphereProfile) -> Vector3:
	return profile.absorption_beta * profile.absorption_width + haze_depth(profile) * (1.0 - profile.mie_albedo)


## Albedo of a conservative column of [param gamma_tau] over a ground of albedo [param ground], one
## channel: the GDScript twin of far_air() in terrain_far_light.gdshaderinc, for the tests and the figures above.
static func column_albedo(gamma_tau: float, ground: float) -> float:
	var g := (1.0 - ground) * gamma_tau
	return (ground + g) / (1.0 + g)


## Pixels per radian of a view [param viewport_height_px] tall at [param fov_deg] vertical.
static func pixels_per_radian(viewport_height_px: float, fov_deg: float) -> float:
	return viewport_height_px / (2.0 * tan(deg_to_rad(clampf(fov_deg, 1.0, 179.0)) * 0.5))


## The level for a body: [param own_body] is the player's, [param air_px] its air's thickness on screen,
## [param previous] the level it had (for the shell's hysteresis).
static func choose(air: bool, own_body: bool, air_px: float, previous: Level) -> Level:
	if not air:
		return Level.NONE
	if own_body:
		return Level.OWN
	if air_px >= SHELL_ON_PX or (previous == Level.SHELL and air_px >= SHELL_OFF_PX):
		return Level.SHELL
	return Level.DISC


## The terrain shader's far-air instance uniforms for [param profile] at [param at_level]: the column's
## scattering (xyz) with 1 in w — the shader's on switch — and its absorption; w = 0 at OWN and NONE.
static func chunk_params(profile: AtmosphereProfile, at_level: Level) -> Dictionary:
	if not has_air(profile) or not (at_level == Level.SHELL or at_level == Level.DISC):
		return {"far_air_scattering": Vector4.ZERO}
	var gamma_tau := column_gamma_tau(profile)
	return {
		"far_air_scattering": Vector4(gamma_tau.x, gamma_tau.y, gamma_tau.z, 1.0),
		"far_air_absorption": column_absorption(profile),
	}


## Choose this body's level for this frame and keep the shell in step. [param body_center] is the body's
## centre and [param camera] the camera, both in world space (float64: only their difference reaches the
## GPU); [param own_body] whether the player is on it; [param to_star] the direction to the star.
## True when the level changed: the caller then hands chunk_params to its chunks.
func update(body_center: Vector3, camera: Camera3D, own_body: bool, to_star: Vector3) -> bool:
	var previous := level
	var air_px := 0.0
	var relative: Vector3 = body_center - camera.global_position
	var distance: float = relative.length()
	if distance > 1.0:
		var per_rad := pixels_per_radian(camera.get_viewport().get_visible_rect().size.y, camera.fov)
		air_px = _profile.atmosphere_top / distance * per_rad
	level = choose(has_air(_profile), own_body, air_px, previous)
	if _shell != null:
		_shell.visible = level == Level.SHELL
		if _shell.visible:
			var material := _shell.material_override as ShaderMaterial
			material.set_shader_parameter("planet_center", relative)
			material.set_shader_parameter("to_star", to_star)
	return level != previous


## Free the shell (the body leaves, the terrain goes).
func release() -> void:
	if is_instance_valid(_shell):
		_shell.queue_free()
	_shell = null


func _make_shell(light_color: Color, light_energy: float) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = SHELL_RADIAL_SEGMENTS
	sphere.rings = SHELL_RINGS
	var material := ShaderMaterial.new()
	material.shader = SHELL_SHADER
	for key: String in ["planet_radius", "atmosphere_top", "rayleigh_beta", "rayleigh_scale_height", "mie_beta",
			"mie_g", "mie_albedo", "haze_top", "haze_bottom", "absorption_beta", "absorption_center"]:
		material.set_shader_parameter(key, _profile.get(key))
	material.set_shader_parameter("haze_falloff", maxf(_profile.haze_falloff, 1.0))
	material.set_shader_parameter("mie_scale_height", maxf(_profile.mie_scale_height, 1.0))
	material.set_shader_parameter("absorption_width", maxf(_profile.absorption_width, 1.0))
	# The terrain's units: its star lights a white ground at light_energy, so the air's radiance is
	# scaled the same way (irradiance 1, PI x energy: a Lambertian ground under 1 W/m2 sends 1/PI).
	material.set_shader_parameter("star_irradiance", 1.0)
	material.set_shader_parameter("star_color", Vector3(light_color.r, light_color.g, light_color.b))
	material.set_shader_parameter("sky_exposure", PI * light_energy)
	material.set_shader_parameter("view_steps", SHELL_VIEW_STEPS)
	material.set_shader_parameter("light_steps", SHELL_LIGHT_STEPS)
	var shell := MeshInstance3D.new()
	shell.name = "AtmosphereShell"
	shell.mesh = sphere
	shell.material_override = material
	shell.scale = Vector3.ONE * (_profile.planet_radius + _profile.atmosphere_top)
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.layers = GlobalsDefs.RENDER_MASK_CELESTIAL
	shell.visible = false
	return shell
