class_name MoonLights
extends Node

## Client-only moonlight: one DirectionalLight3D per moon of the body the player is standing on,
## built exactly like PlayerSunLight but aimed from the moon.
##
## Nothing here is authored. A moon's brightness is what its own geometry gives:
##   full-phase fraction = (2/3) * albedo * (radius / distance)^2
## of the starlight the moon receives, times its phase, times the air the light then crosses on its
## way down to the player. Korax comes out at 8.9 times our own full moon, which is what the study
## predicts for a body 2.96 times the Moon's apparent size.
##
## Sandbox's two moons have synodic periods of 32.05 h and 26.16 h against a 25 h day, so the three
## cycles beat against each other and no two nights are alike. That comes out of the orbits for free;
## it is only visible if the moons actually light something.

## Above this fraction of the star's own energy a moon is worth a shadow pass. Only the brightest
## moon gets one, and only at night: two sets of cast shadows from sources 5 orders of magnitude
## apart is a cost with nothing to show for it.
const SHADOW_WORTH_FRACTION := 5.0e-06

## Stand-in for dark adaptation, and the ONE number in this lot that is not physics.
##
## Korax at full phase and at the zenith lands 6.2e-6 in engine units on the ground — physically
## right, and a black screen. We see by moonlight because the eye opens; this engine will not, because
## `rendering/lights_and_shadows/use_physical_light_units` is off, which leaves CameraAttributes'
## ISO sensitivities without the meaning that would let auto-exposure bridge a million to one
## (measured: a gain of a few, against the 1e5 needed).
##
## The target is a RATIO, not an absolute level: a full Korax should read at about one hundredth of
## full daylight, which is roughly what a dark-adapted eye reports between a moonlit landscape and a
## sunlit one. 500 gives 1/96 at full phase and 1/193 at half. An earlier value of 8000 was set from
## an absolute figure without comparing it to the day, and put a HALF moon at one twelfth of daylight
## — a permanent twilight rather than a night.
##
## It is a pure SCALE. Every ratio around it stays derived: the reflected fraction from each moon's
## own size, distance and albedo, the phase, the extinction with elevation. Turning this knob moves
## all the moons together and changes none of their relationships.
@export var moon_light_gain: float = 500.0

## Development switch, toggled by the `debug_toggle_moon_lights` action. OFF means the moons light
## NOTHING, which is the only way to tell their contribution apart from the city's own lamps and
## from a wall simply catching a grazing light face-on. Judging moonlight by eye without it is
## guesswork: a directional light at the horizon hits vertical walls at full cosine and the ground
## at almost none, so a moon setting LOOKS like it is brightening the buildings.
@export var moon_lights_enabled: bool = true

## The owned player body (set by PlayerClient).
var player: Node3D = null
## The star's light, for the shared aiming, the reddening ramp and the reference energy.
var sun: PlayerSunLight = null
## The air the moonlight has to cross, and the resolver for which body we are on.
var atmosphere: AtmosphereRenderer = null

var _lights: Dictionary = {}
## Name of the body we last reported moons for, so the line below is printed on arrival and not
## sixty times a second.
var _reported_body: String = ""


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)  # moonlight is a client-side visual
		return
	process_priority = 120  # after the sun (100) and the atmosphere (110): both are read below


func _process(_delta: float) -> void:
	if not is_instance_valid(player) or not is_instance_valid(sun) or not is_instance_valid(atmosphere):
		return
	var moons := _moons_of_current_body()
	if not moons_lights_enabled_now():
		_drop_lights_not_in([])
		return
	var brightest: Node3D = null
	var brightest_fraction := 0.0
	var contributions := {}
	for moon in moons:
		var fraction := _reflected_fraction(moon)
		contributions[moon] = fraction
		if fraction > brightest_fraction:
			brightest_fraction = fraction
			brightest = moon
	for moon in moons:
		_apply_moon(moon, contributions[moon], moon == brightest)
	_drop_lights_not_in(moons)


## One line per moon: what each factor of the energy chain is actually worth right now. Printed on
## demand rather than shown in the HUD, because the interesting moment is a specific one -- a given
## phase at a given elevation -- and because it is the only way to tell WHICH factor is eating the
## light. Measured from a screenshot, the ground was rendering 200 times below what the gain says it
## should, and no amount of looking could say whether the phase, the extinction or the gain was
## responsible.
func report_now() -> void:
	if not is_instance_valid(player) or not is_instance_valid(sun):
		return
	print("[MoonLights] gain=%.0f  interrupteur=%s  sun_energy=%.2f"
		% [moon_light_gain, "on" if moon_lights_enabled else "OFF", sun.sun_energy])
	for moon in _moons_of_current_body():
		var to_moon: Vector3 = moon.global_position - player.global_position
		if to_moon.length_squared() < 0.0001:
			continue
		to_moon = to_moon.normalized()
		var fraction := _reflected_fraction(moon)
		var phase := _phase(moon, to_moon)
		var elevation: float = sun.stable_up().dot(to_moon)
		var extinction: Color = atmosphere.transmittance_at(elevation)
		var brightest: float = maxf(extinction.r, maxf(extinction.g, extinction.b))
		# Parts per million rather than scientific notation: Godot's String % has NO %e, and using
		# one fails at RUNTIME with "unsupported format character", printing the format string
		# itself and aborting the rest of the function.
		print("   %-10s fraction=%.2f ppm  phase=%.3f  elevation=%+.1f deg  extinction=%.3f  -> energie=%.5f"
			% [moon.name, fraction * 1.0e6, phase,
			rad_to_deg(asin(clampf(elevation, -1.0, 1.0))),
			brightest, sun.sun_energy * fraction * phase * brightest * moon_light_gain])


## True while the moons are allowed to light the world. Kept as a function so the switch has one
## reader, and so turning it off DROPS the lights rather than leaving them at their last energy.
func moons_lights_enabled_now() -> bool:
	return moon_lights_enabled


## The moons of the body the player is on. On the client a moon is parented UNDER its planet (the
## network sends its position relative to that planet), so they are simply its Planet children.
func _moons_of_current_body() -> Array:
	var body := atmosphere.current_body()
	if body == null:
		return []
	var moons := []
	for child in body.get_children():
		if child is Planet:
			moons.append(child)
	_report_once(body, moons)
	return moons


## Say what was found, once per body. A moon that never turns up would otherwise be a silent nothing:
## the lights are a millionth of daylight, so their absence looks exactly like their presence.
func _report_once(body: Planet, moons: Array) -> void:
	if _reported_body == body.name:
		return
	_reported_body = body.name
	var names := []
	for moon in moons:
		names.append("%s (albedo %.2f, r %.0f km)" % [moon.name, moon.surface_albedo, moon.map_radius_km])
	prints("[MoonLights] %s: %d moon(s) %s" % [body.name, moons.size(), ", ".join(names)])


## Fraction of the star's irradiance that this moon reflects down to the player at FULL phase.
## Uses the live distance rather than the orbit's semi-major axis, so an eccentric moon brightens
## at periapsis on its own.
func _reflected_fraction(moon: Node3D) -> float:
	var radius: float = (moon as Planet).map_radius_km * 1000.0
	var albedo: float = (moon as Planet).surface_albedo
	if radius <= 0.0 or albedo <= 0.0:
		return 0.0
	var distance: float = (moon.global_position - player.global_position).length()
	if distance <= radius:
		return 0.0
	var ratio: float = radius / distance
	return 2.0 / 3.0 * albedo * ratio * ratio


## Place, aim and dim one moon's light.
func _apply_moon(moon: Node3D, full_fraction: float, is_brightest: bool) -> void:
	var light := _light_for(moon)
	# Subtract the two float64 world positions BEFORE normalising: at ~3e10 the difference is the
	# only part that carries any precision.
	var to_moon: Vector3 = moon.global_position - player.global_position
	if to_moon.length_squared() < 0.0001 or full_fraction <= 0.0:
		light.visible = false
		return
	to_moon = to_moon.normalized()
	var up: Vector3 = sun.stable_up()
	var elevation: float = up.dot(to_moon)
	# The same air that reddens the star reddens the moon, and it is what makes the light vanish as
	# the moon sets: below the horizon the body itself blocks the ray and the transmittance is black.
	var extinction: Color = atmosphere.transmittance_at(elevation)
	# Same split as the star: the strongest channel carries the brightness, the ratios carry the hue.
	var brightest: float = maxf(extinction.r, maxf(extinction.g, extinction.b))
	var energy: float = (
		sun.sun_energy * full_fraction * _phase(moon, to_moon) * brightest * moon_light_gain
	)
	light.visible = energy > 0.0
	if not light.visible:
		return
	light.global_transform = Transform3D(
		PlayerSunLight.aim_basis(to_moon, up, player.global_transform.basis.x), player.global_position
	)
	# A moon low on the horizon reddens exactly like a low star, and for the same reason.
	light.light_color = PlayerSunLight.star_tint(extinction)
	light.light_energy = energy
	# Shadows for the brightest moon only, and only once the star is down: while it is up its own
	# shadows are five orders of magnitude stronger and these would be invisible anyway.
	var star_is_up: bool = up.dot(sun.star_direction) > 0.0
	light.shadow_enabled = (
		is_brightest and not star_is_up and full_fraction > SHADOW_WORTH_FRACTION
		and SettingsManager.is_shadows()
	)


## Illuminated fraction of the moon's disc as seen from here: 1 at full, 0 at new. The phase angle is
## measured AT THE MOON, between the star and the player — which is what decides how much of the lit
## hemisphere faces us.
func _phase(moon: Node3D, to_moon: Vector3) -> float:
	var star: Node3D = sun.get_star()
	if star == null:
		return 1.0
	var moon_to_star: Vector3 = star.global_position - moon.global_position
	if moon_to_star.length_squared() < 0.0001:
		return 1.0
	var cos_alpha: float = moon_to_star.normalized().dot(-to_moon)
	return (1.0 + cos_alpha) * 0.5


## The light of one moon, created on first sight. Parented to this node rather than to the moon: like
## the sun it is placed on the PLAYER every frame, because a directional light's position only decides
## where its shadow cascade sits.
func _light_for(moon: Node3D) -> DirectionalLight3D:
	if _lights.has(moon):
		return _lights[moon]
	var light := DirectionalLight3D.new()
	light.name = "MoonLight_%s" % moon.name
	# Local surfaces only, for the same reason as the sun: a distant body is lit by the system star's
	# OmniLight from the real direction, and this light is aimed moon->PLAYER.
	light.light_cull_mask = Globals.RENDER_MASK_LOCAL
	light.light_volumetric_fog_energy = 0.0
	light.shadow_opacity = 0.69
	light.shadow_blur = 1.649
	light.directional_shadow_max_distance = SettingsManager.get_shadow_distance()
	add_child(light)
	_lights[moon] = light
	return light


## Forget the lights of moons that are no longer around — the player changed body, or the moon left
## the tree. Without this, travelling would accumulate a light per moon ever seen.
func _drop_lights_not_in(moons: Array) -> void:
	for moon in _lights.keys():
		if moons.has(moon) and is_instance_valid(moon):
			continue
		var light: DirectionalLight3D = _lights[moon]
		if is_instance_valid(light):
			light.queue_free()
		_lights.erase(moon)
