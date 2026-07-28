class_name PlayerSunLight
extends DirectionalLight3D

## Client-only "sun" for the LOCAL player. The system star (scenes/star/star.tscn) is an OmniLight that
## lights the whole system radially but casts NO shadows (a distant point light gives unusable cubemap
## shadows at astronomic scale). This per-client DirectionalLight is aimed FROM the real star TOWARD the
## player, so it provides crisp cast shadows and the day/night look driven by the real star direction
## (not a fake rotating cycle). PlayerClient creates it for the OWNER only; never networked.

## Directional light energy. This is now the SOLE light on the local surface (the star OmniLight was
## culled off it), so it carries all of daytime — raised from 1.0 to make up for the removed OmniLight,
## which used to roughly double the light near the player. Tune in-game (live @export).
@export var sun_energy: float = 2.0
## Warm-at-horizon -> white-at-noon colour ramp, sampled by the star's real elevation above the horizon.
@export var sun_tint: Gradient

## The owned player body this sun follows (set by PlayerClient right after instancing).
var player: Node3D = null
var _star: Node3D = null
## Full-day sky energy, captured once from the camera's PhysicalSkyMaterial (-1 = not captured yet).
var _sky_energy_day: float = -1.0
## Ground-level volumetric fog density, captured once from the camera Environment (-1 = not captured).
var _fog_density_ground: float = -1.0
## Stabilised up-direction. The raw player.up_direction occasionally swings for a few frames on the
## ground (the AreaDetector gravity stack briefly resolves to a wrong/overlapping area). Feeding that
## straight into the day factor flashed the whole sky black. We follow the raw up while it moves
## gradually (real walking / planet spin) and IGNORE a sudden large swing — unless it persists, which
## means a genuine change of body (a teleport), and then we snap to it.
var _up_stable: Vector3 = Vector3.ZERO
var _up_bad_frames: int = 0

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)  # shadows are a client-side visual; the headless server has no sun
		return
	# Re-place the sun AFTER the player role has moved the body this frame (higher priority = processed
	# later), so it sits on the player's final position instead of lagging one frame behind.
	process_priority = 100
	# Do NOT light the volumetric fog with this sun. It is re-oriented every frame at ~3e10 coords, and
	# the fog's temporal reprojection turns that per-frame change into a black FLICKER of the whole
	# hazy view. Decoupling the fog from the moving light kills the flicker; the fog stays ambient-lit.
	light_volumetric_fog_energy = 0.0
	# Light ONLY the local render layer. Distant bodies rendered on the celestial layer (far-LOD spheres
	# and, when far, terrain chunks) are lit by the system star's OmniLight from the REAL star direction;
	# this per-player sun is aimed star->PLAYER, wrong for a distant body, so it must not touch them.
	light_cull_mask = Globals.RENDER_MASK_LOCAL
	shadow_opacity = 0.69  # softened shadow look carried over from the temporary day/night sun
	shadow_blur = 1.649
	if sun_tint == null:
		sun_tint = _build_default_sun_tint()
	# Real-time shadows gated by the graphics settings (default on), reacting live to menu changes.
	shadow_enabled = SettingsManager.is_shadows()
	directional_shadow_max_distance = SettingsManager.get_shadow_distance()
	SettingsManager.shadows_changed.connect(_on_shadows_changed)
	SettingsManager.shadow_distance_changed.connect(_on_shadow_distance_changed)

func _process(delta: float) -> void:
	if not is_instance_valid(player):
		return
	if not is_instance_valid(_star):
		_star = _find_star()
		if _star == null:
			return
	# Direction player -> star. Subtract the two float64 world positions BEFORE normalising (never
	# normalise two ~3e10 positions apart) so it stays exact at astronomic coordinates.
	var to_star: Vector3 = _star.global_position - player.global_position
	if to_star.length_squared() < 0.0001:
		return
	to_star = to_star.normalized()
	# Stabilised up (centre planet -> player): reject a momentary gravity-area glitch, follow real motion.
	var up_raw: Vector3 = (player as CharacterBody3D).up_direction
	if _up_stable == Vector3.ZERO:
		_up_stable = up_raw
	elif up_raw.dot(_up_stable) > 0.9:  # within ~25deg: a real, gradual change -> follow it
		_up_stable = _up_stable.slerp(up_raw, minf(delta * 5.0, 1.0)).normalized()
		_up_bad_frames = 0
	else:  # a sudden large swing: ignore it as a glitch, unless it persists (a real teleport) -> snap
		_up_bad_frames += 1
		if _up_bad_frames > 20:
			_up_stable = up_raw
			_up_bad_frames = 0
	# Star elevation above the local horizon: > 0 = day, < 0 = night (magnitude = sine of elevation).
	var elevation: float = _up_stable.dot(to_star)
	# Day/night factor: 1 in full day, 0 below the horizon, a soft band across the terminator. The SAME
	# factor drives the sun energy AND the sky, so the sky-sourced ambient and reflections (which never
	# pass through a light() function) darken in step -> a truly black night. Because up is stabilised,
	# a genuine sunset (planet spin) crosses the band over minutes while glitches no longer reach it.
	var day: float = smoothstep(-Globals.TERMINATOR_SOFTNESS, Globals.TERMINATOR_SOFTNESS, elevation)
	_apply_night_sky(day)
	# Crossfade the day/night GATING by altitude. On the ground the sun is gated on your local day/night
	# (off at your night) so shadows and total-black night work. High up and in space the gate is lifted
	# and the sun stays on, letting its NdotL paint the true terminator across the whole visible surface
	# — the day side lit, the night side dark — which is what the far-LOD sphere shows. This is what makes
	# the chunk lighting match the sphere instead of going uniformly black over the night side at altitude.
	var alt: float = _altitude_crossfade()
	var final_energy: float = sun_energy * lerpf(day, 1.0, alt)
	visible = final_energy > 0.001
	if visible:
		# Build the orientation EXPLICITLY — do NOT use look_at() here: its target is derived from a ~3e10
		# world position and the resulting orientation comes out wrong at astronomic coordinates (the
		# light then just follows its parent, so the shadows spin with the camera). A DirectionalLight
		# shines along its -Z and we want rays FROM the star TO the player, so its +Z axis must BE
		# to_star. Assigning global_transform locks it in world space, immune to the body's mouse yaw.
		var up_ref: Vector3 = _up_stable if absf(_up_stable.dot(to_star)) < 0.999 else player.global_transform.basis.x
		var x_axis: Vector3 = up_ref.cross(to_star)
		if x_axis.length_squared() < 0.000001:
			x_axis = player.global_transform.basis.x.cross(to_star)  # degenerate: star straight overhead
		x_axis = x_axis.normalized()
		var y_axis: Vector3 = to_star.cross(x_axis).normalized()
		global_transform = Transform3D(Basis(x_axis, y_axis, to_star), player.global_position)
		# Warm the light near the horizon (sunrise/sunset), white at the zenith.
		light_color = sun_tint.sample(clampf(elevation, 0.0, 1.0))
		light_energy = final_energy
	# Fade the fog with altitude. Runs LAST, after the sun is fully set, so nothing in it can ever
	# skip the sun above (whatever the body/state), and it still updates at night (fog is not gated on day).
	_apply_atmosphere_fade()

## Fade the sky (and therefore its ambient light and reflections) with the day factor, so night is
## truly black. Ambient/reflections bypass light() entirely, so nothing else can darken them. Drives
## the PhysicalSkyMaterial energy on the player camera's Environment (built by
## PlayerClient._force_temp_sky_environment). The full-day energy is captured once from that material,
## so its value is not duplicated here.
func _apply_night_sky(day: float) -> void:
	if not is_instance_valid(player) or player.camera == null:
		return
	var env: Environment = player.camera.environment
	if env == null or env.sky == null:
		return
	var psm := env.sky.sky_material as PhysicalSkyMaterial
	if psm == null:
		return
	if _sky_energy_day < 0.0:
		_sky_energy_day = psm.energy_multiplier
	psm.energy_multiplier = _sky_energy_day * day

## 0 near the ground (sun gated on your local day/night, with shadows), rising to 1 high up and in deep
## space (gate lifted -> the sun stays on and its NdotL draws the true day/night terminator across the
## visible surface, matching the far-LOD sphere). Crossfades over the atmosphere so the ground keeps its
## shadows while a view from altitude/orbit sees the whole planet's terminator, seamlessly across the LOD.
func _altitude_crossfade() -> float:
	var area: Node = player.get_current_gravity_parent()
	if area == null or area.get_parent() == null:
		return 1.0  # deep space: no ground to shadow — full terminator mode
	var planet: Node = area.get_parent().get_parent()
	if not (planet is Planet):
		return 1.0
	var data: PlanetData = (planet as Planet).planet_data
	if data == null:
		return 1.0
	var top: float = (data.atmosphere_height if data.atmosphere_height > 0.0 else Globals.DEFAULT_ATMOSPHERE_HEIGHT) * 2.0
	var altitude: float = (player.global_position - (planet as Node3D).global_position).length() - data.radius
	return smoothstep(0.0, top, altitude)

## Fade the volumetric fog with altitude: full at the surface, gone at the top of the atmosphere, gone
## in space. Fog/haze is atmospheric, so it must thin as the air thins with height — otherwise it hangs
## in orbit. TEMPORARY, like the _force_temp_sky_environment it drives. The ground density is captured
## once from the Environment rather than duplicated.
func _apply_atmosphere_fade() -> void:
	if not is_instance_valid(player) or player.camera == null:
		return
	var env: Environment = player.camera.environment
	if env == null:
		return
	if _fog_density_ground < 0.0:
		_fog_density_ground = env.volumetric_fog_density
	env.volumetric_fog_density = _fog_density_ground * _atmosphere_factor()

## 1 at the surface of the body the player is on, fading to 0 at the top of its atmosphere and 0 in deep
## space (no gravity body -> no air). A plain centre-radius altitude is enough here (the fade spans tens
## of km, so the few-km terrain height is negligible); uses atmosphere_height, or a placeholder default.
func _atmosphere_factor() -> float:
	var area: Node = player.get_current_gravity_parent()
	if area == null or area.get_parent() == null:
		return 0.0
	var planet: Node = area.get_parent().get_parent()
	if not (planet is Planet):
		return 0.0
	var data: PlanetData = (planet as Planet).planet_data
	if data == null:
		return 0.0
	var height: float = data.atmosphere_height if data.atmosphere_height > 0.0 else Globals.DEFAULT_ATMOSPHERE_HEIGHT
	var altitude: float = (player.global_position - (planet as Node3D).global_position).length() - data.radius
	return clampf(1.0 - altitude / height, 0.0, 1.0)

## Resolve the system star (a static node under the level root). Cached by the caller.
func _find_star() -> Node3D:
	var scene: Node = NetworkOrchestrator.universe_scene
	if scene != null:
		var s: Node = scene.get_node_or_null("Star")
		if s is Node3D:
			return s
	return null

## Live-apply the shadows on/off graphics setting (SettingsManager.shadows_changed).
func _on_shadows_changed(on: bool) -> void:
	shadow_enabled = on

## Live-apply the shadow distance graphics setting (SettingsManager.shadow_distance_changed).
func _on_shadow_distance_changed(distance: float) -> void:
	directional_shadow_max_distance = distance

## Default sun colour ramp (elevation 0 -> 1): deep orange at dawn/dusk fading to white at noon.
func _build_default_sun_tint() -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.12, 0.35, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 0.32, 0.12),
		Color(1.0, 0.55, 0.28),
		Color(1.0, 0.93, 0.84),
		Color(1.0, 1.0, 1.0),
	])
	return gradient
