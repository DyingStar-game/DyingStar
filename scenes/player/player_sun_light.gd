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

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)  # shadows are a client-side visual; the headless server has no sun
		return
	# Re-place the sun AFTER the player role has moved the body this frame (higher priority = processed
	# later), so it sits on the player's final position instead of lagging one frame behind.
	process_priority = 100
	shadow_opacity = 0.69  # softened shadow look carried over from the temporary day/night sun
	shadow_blur = 1.649
	if sun_tint == null:
		sun_tint = _build_default_sun_tint()
	# Real-time shadows gated by the graphics settings (default on), reacting live to menu changes.
	shadow_enabled = SettingsManager.is_shadows()
	directional_shadow_max_distance = SettingsManager.get_shadow_distance()
	SettingsManager.shadows_changed.connect(_on_shadows_changed)
	SettingsManager.shadow_distance_changed.connect(_on_shadow_distance_changed)

func _process(_delta: float) -> void:
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
	var up: Vector3 = (player as CharacterBody3D).up_direction  # centre planet -> player, kept by PlayerClient
	# Star elevation above the local horizon: > 0 = day, < 0 = night (magnitude = sine of elevation).
	var elevation: float = up.dot(to_star)
	# Smooth day/night factor: 1 in full day, 0 below the horizon, a soft band across the terminator.
	# The SAME factor drives the sun energy AND the sky, so the sky-sourced ambient and reflections
	# (which never pass through a light() function) darken in step -> a truly black night, not a snap.
	var day: float = smoothstep(-Globals.TERMINATOR_SOFTNESS, Globals.TERMINATOR_SOFTNESS, elevation)
	_apply_night_sky(day)
	visible = day > 0.0
	if not visible:
		return
	# Build the orientation EXPLICITLY — do NOT use look_at() here: its target is derived from a ~3e10
	# world position and the resulting orientation comes out wrong at astronomic coordinates (the light
	# then just follows its parent, so the shadows spin with the camera). A DirectionalLight shines along
	# its -Z and we want rays FROM the star TO the player, so its +Z axis must BE to_star. Assigning
	# global_transform locks it in world space, immune to the player body's mouse-look yaw.
	var up_ref: Vector3 = up if absf(up.dot(to_star)) < 0.999 else player.global_transform.basis.x
	var x_axis: Vector3 = up_ref.cross(to_star)
	if x_axis.length_squared() < 0.000001:
		x_axis = player.global_transform.basis.x.cross(to_star)  # degenerate: star straight overhead
	x_axis = x_axis.normalized()
	var y_axis: Vector3 = to_star.cross(x_axis).normalized()
	global_transform = Transform3D(Basis(x_axis, y_axis, to_star), player.global_position)
	# Warm the light near the horizon (sunrise/sunset), white at the zenith.
	light_color = sun_tint.sample(clampf(elevation, 0.0, 1.0))
	light_energy = sun_energy * day

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
