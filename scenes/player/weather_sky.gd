class_name WeatherSky
extends RefCounted
## What the weather does to the sky: it thickens the veil and brings it down to the ground. Reads
## the storm dust at the observer (Planet.weather_at) and sets the two knobs AtmosphereRenderer
## exposes, QUANTISED — both are keys of the transmittance table, and a value drifting every frame
## would refill the table every frame. One refill costs a 256×64 pass; a storm ramp of ×1 → ×70
## takes ≈ 50 of them spread over minutes, not one per frame.
##
## The scale: the veil's calibrated optical depth τ₀ = |β_mie|·thickness (1.90 on Sandbox) plus the
## storm's τ at the observer, over τ₀. The floor: a storm fills the valleys, so the slab's bottom
## comes down to the ground as the storm thickens (τ = 1 is enough), in 250 m steps.

## Scale steps: 2^(1/8), eight steps per doubling — invisible to the eye, cheap for the table.
const SCALE_STEP_LOG2: float = 0.125
const FLOOR_STEP_M: float = 250.0
## The storm τ at which the slab reaches the ground.
const FLOOR_FULL_TAU: float = 1.0
## How often the weather is read, seconds.
const REFRESH_S: float = 0.5
## The blown-dust slab: the visibility (m) a full blow (twice the ground's lift threshold) brings the
## plains down to — Koschmieder, β = 3.912 / V — and how the density rises to it with the lift
## (StormDust.saltation_rate); the slab from this far under the observer's ground to this far over it.
const BLOW_VISIBILITY_FULL_M: float = 400.0
const BLOW_POWER: float = 1.5
const BLOW_BELOW_M: float = 30.0
const BLOW_ABOVE_M: float = 80.0
## What the blown dust reflects at most (its brightest channel), and the colour it takes when the
## ground under the observer has none to give (a pale ochre, the corundum plains).
const BLOW_ALBEDO_MAX: float = 0.92
## The dust layer near the eye against the model's extinction (1 = the model's visibility at the
## ground), and the period (m) its noise offset is wrapped at.
const DUST_LAYER_STRENGTH: float = 1.0
const DUST_WRAP_M: float = 100000.0
## The fine gusts travel this much faster than the air (the coarse ones ride it).
const FINE_GUST_SPEED: float = 1.37
## The noise's period (m, the shader's dust_noise_scale), the fine gusts' share of it, the streaks'
## stretch along the wind, how fast their direction follows the wind (1/s), and how far the camera
## goes (m) before the noise's anchor is laid again under it.
const DUST_NOISE_SCALE: float = 110.0
const FINE_SCALE: float = 0.413
const DUST_STRETCH: float = 3.5
const WIND_DIR_RATE: float = 0.3
const ANCHOR_RESET_M: float = 4000.0
## The noise texture: texels a side, and cells across one period (a feature ≈ period / cells).
const NOISE_TEXELS: int = 128
const NOISE_CELLS: float = 14.0
const BLOW_FALLBACK_COLOUR: Color = Color(0.86, 0.74, 0.56)

var _last_read_at: float = -INF
var _dust_density: float = 0.0
var _dust_wind: Vector3 = Vector3.ZERO
var _dust_sent: bool = false
var _scroll: Vector3 = Vector3.ZERO
var _scroll_fine: Vector3 = Vector3.ZERO
var _wind_dir: Vector3 = Vector3.ZERO
var _anchor: Vector3 = Vector3.ZERO
var _anchor_set: bool = false
var _noise: NoiseTexture3D = null
## The real ground around the camera the layer lies on (DustGround), and the planet it was laid on.
var _ground: DustGround = DustGround.new()
var _ground_planet: int = 0
## The storms around the camera, near and far (StormField), the planet they were laid on, the camera's
## height over the ground (m, for the dust column over the eye), and the client.ini A/B switch.
var _storm: StormField = StormField.new()
var _storm_planet: int = 0
var _cam_height: float = 1.7
var _tau_above: float = 0.0
## The storm column over the eye (m, < 0 = over the lid), the lid's top and the ground under the
## camera (m over the planet's reference sphere), from the storm grid (StormField.lid_at).
var _column_m: float = 0.0
var _lid_top_elev_m: float = 0.0
var _ground_elev_m: float = 0.0
var _lid_known: bool = false
var _no_storm_volume: bool = ClientConfig.get_bool("debug_no_storm_volume", false)
## client.ini debug_no_veil: the profile's Mie veil (Sandbox's corundum) at zero, everything else kept.
var _no_veil: bool = ClientConfig.get_bool("debug_no_veil", false)
## client.ini debug_dust_storm_km: a test dust storm laid this far ahead of the camera on the first
## frame (0 = none), to see the far volume without waiting for a real one to come by.
var _test_storm_km: float = ClientConfig.get_float("debug_dust_storm_km", 0.0)
var _test_storm_laid: bool = false
## The blown slab: faded out between these heights of the eye over the ground (m), and glided toward
## each reading at this rate (1/s) instead of laid at once.
const BLOW_FADE_FROM_M: float = 50.0
const BLOW_FADE_TO_M: float = 300.0
const BLOW_GLIDE_RATE: float = 4.0
var _blow_target_beta: float = 0.0
var _blow_target_bottom: float = 0.0
var _blow_target_top: float = 0.0
var _blow_laid: bool = false
var _slab_target_beta: float = 0.0
var _slab_target_bottom: float = 0.0
var _slab_target_top: float = 0.0
## The dust's asymmetry (corundum's forward scattering, the veil's mie_g) for the two-stream diffuse
## light under a storm, and the share of that diffuse light the dust's ambient term takes.
const DUST_G: float = 0.7
const DUST_DIFFUSE_SHARE: float = 0.55
## The period (m) of the noise that twists the storm dust's colour boundaries.
const STORM_COLOUR_NOISE_M: float = 9000.0
## The periods (m) of the two noises that make a storm's top billow: the noise texture holds ~14
## features a period (NOISE_CELLS), so domes of ~3 km, smaller ones of ~0.8 km and puffs of ~250 m.
const STORM_LID_NOISE_A_M: float = 40000.0
const STORM_LID_NOISE_B_M: float = 12000.0
const STORM_LID_NOISE_C_M: float = 3500.0
## How the billows move: this share of the ground wind carries them, and the noise slides along the
## local up at this speed (m/s) so the domes swell and sink. Their travel so far (planet frame, m).
const STORM_DRIFT_SHARE: float = 0.6
const STORM_CHURN_M_S: float = 4.0
var _storm_drift: Vector3 = Vector3.ZERO
var _storm_churn: float = 0.0
## The test storm: 60 km across, the τ of a strong real one.
const TEST_STORM_RADIUS_M: float = 60000.0
const TEST_STORM_TAU: float = 6.0
## The dust probe (client.ini debug_dust_probe=true): what was sent to the layer last frame, to log
## every discontinuity of it. Off, it costs a bool test.
var _probe_start: float = 0.0
var _sheltered_start: bool = false
var _no_dust_layer: bool = ClientConfig.get_bool("debug_no_dust_layer", false)
var _probe_on: bool = ClientConfig.get_bool("debug_dust_probe", false)
var _probe_last: Dictionary = {}
var _probe_light_last: Array = []
var _probe_summary_at: int = 0
var _refills: int = 0


## Apply the weather at [param observer_world_pos] on [param planet] to [param renderer]. Returns the
## quantised [scale, floor_m] it set (floor -1 = the profile's own).
func update(renderer: AtmosphereRenderer, planet: Planet, observer_world_pos: Vector3) -> Array:
	var now: float = Time.get_ticks_msec() * 0.001
	if now - _last_read_at < REFRESH_S:
		return [renderer.weather_haze_scale, renderer.weather_haze_floor_m]
	_last_read_at = now
	var profile: AtmosphereProfile = planet.planet_data.atmosphere_profile if planet.planet_data != null else null
	var sample: Dictionary = planet.weather_at(observer_world_pos)
	var tau_here: float = float(sample.get("dust_tau", 0.0))
	# With the storm volume (StormField) drawing the storms, near and far, the veil stays calibrated:
	# thickening it around the observer as well counted the storm twice. Its light side, the star
	# dimmed through the dust overhead, goes to the renderer as the column's depth over the eye.
	var storm_volume: bool = storm_volume_on(planet)
	var column: float = maxf(_column_m, 0.0) if _lid_known \
			else clampf(WeatherSampler.DUST_LAYER_M - _cam_height, 0.0, WeatherSampler.DUST_LAYER_M)
	_tau_above = tau_here * column / WeatherSampler.DUST_LAYER_M if storm_volume else 0.0
	renderer.weather_storm_tau_above = _tau_above
	var knobs: Array = knobs_for(profile, 0.0 if storm_volume else tau_here)
	if knobs[0] != renderer.weather_haze_scale or knobs[1] != renderer.weather_haze_floor_m:
		_refills += 1
	renderer.weather_haze_scale = knobs[0]
	renderer.weather_haze_floor_m = knobs[1]
	if _no_veil or WeatherBench.no_veil:
		renderer.weather_haze_scale = 0.0  # client.ini debug_no_veil: the corundum veil gone, sky and light
		renderer.weather_haze_floor_m = -1.0
	# The dust the wind blows off this ground: a thin Mie slab about the observer's own elevation.
	var climate: ClimateProfile = planet.climate_profile()
	var lifted: float = StormDust.saltation_rate(float(sample.get("wind_speed_m_s", 0.0)),
			climate.v10_threshold_m_s if climate != null else 0.0)
	# Targets only: smooth_blow glides the renderer's values to them every frame. Laid at once every
	# REFRESH_S, the slab's height jumped by hundreds of metres under a fast camera and the horizon
	# blinked. Faded out as the eye leaves the ground: the lift is a ground thing, and kept at 47 km
	# up it drew a shell round the planet, a dark band over the horizon.
	_blow_target_beta = 0.0 if WeatherBench.no_blow \
			else blow_extinction(lifted) * (1.0 - smoothstep(BLOW_FADE_FROM_M, BLOW_FADE_TO_M, _cam_height))
	var ground_dir: Vector3 = planet.local_dir_of(observer_world_pos)
	var ground_colour: Color = GroundLook.at(planet.planet_data, ground_dir, BLOW_FALLBACK_COLOUR).color \
			if not ground_dir.is_zero_approx() else BLOW_FALLBACK_COLOUR
	renderer.weather_blow_albedo = blow_albedo_of(ground_colour)
	# The wind's dust layer near the eye: the same extinction as the slab (the lift), plus the storm's
	# when no storm volume carries it.
	_dust_density = (blow_extinction(lifted) + (0.0 if storm_volume else tau_here / WeatherSampler.DUST_LAYER_M)) \
			* DUST_LAYER_STRENGTH
	if _no_dust_layer or WeatherBench.no_layer:
		_dust_density = 0.0  # client.ini debug_no_dust_layer / the GPU bench: the layer's cost and look
	_dust_wind = planet.wind_world_at(observer_world_pos)
	# Under a roof and between walls the layer starts past the room (ShelterProbe.REACH_M): it is drawn
	# over the whole screen, so the room is kept clear by depth, and the windows still show the outside.
	var shelter_v: Variant = renderer.player.get("weather_shelter") if is_instance_valid(renderer.player) else null
	# A room the masks know is kept clear by them; a shelter they do not (a cab, a building too small
	# or not found) starts the march past its walls instead.
	# With a hysteresis (on above 0.6, off under 0.4): a shelter hovering about one half made the march's
	# start jump between 0 and 8 m, the near dust popping in and out (DustProbe "start 8 -> 0").
	var boxed: bool = renderer.weather_masks != null and renderer.weather_masks.inside(observer_world_pos)
	var shelter_now: float = float((shelter_v as Dictionary).get("shelter", 0.0)) if shelter_v is Dictionary else 0.0
	if boxed or shelter_now < 0.4:
		_sheltered_start = false
	elif shelter_now > 0.6:
		_sheltered_start = true
	var start: float = ShelterProbe.REACH_M if _sheltered_start else 0.0
	renderer.set_dust_param(&"dust_start", start)
	_probe_start = start
	renderer.set_dust_param(&"dust_density", _dust_density)
	renderer.set_dust_param(&"dust_albedo", renderer.weather_blow_albedo)
	# The GROUND's elevation under the observer, not the observer's: elevation_of(observer) followed the
	# body up, and in god mode or EVA the slab floated at eye level, the line of sight running along it
	# to the horizon: the dark band that went with the blown slab (Alt+U stage 1, 2026-10-08).
	var ground: float = planet.elevation_of(observer_world_pos)
	if planet.planet_data != null and not ground_dir.is_zero_approx():
		ground = planet.planet_data.crack_aware_surface_dist(ground_dir) - planet.planet_data.radius
	_blow_target_bottom = ground - BLOW_BELOW_M
	_blow_target_top = ground + BLOW_ABOVE_M
	# The storm the observer stands in, for the sky dome (its diffuse light): the sampler's τ here over
	# DUST_LAYER_M from the ground, the ground's colour; gone once the eye rises out of the column (the
	# volume shows it from outside).
	var over_top: float = -_column_m if _lid_known else _cam_height - WeatherSampler.DUST_LAYER_M
	_slab_target_beta = tau_here / WeatherSampler.DUST_LAYER_M * (1.0 - smoothstep(0.0, 300.0, over_top)) \
			if storm_volume else 0.0
	_slab_target_bottom = _ground_elev_m - BLOW_BELOW_M
	_slab_target_top = _lid_top_elev_m if _lid_known else _ground_elev_m + WeatherSampler.DUST_LAYER_M
	renderer.weather_storm_slab_albedo = renderer.weather_blow_albedo
	if not _blow_laid:  # the first time, at once: no glide up from 0 m on arrival
		_blow_laid = true
		renderer.weather_blow_beta = _blow_target_beta
		renderer.weather_blow_bottom_m = _blow_target_bottom
		renderer.weather_blow_top_m = _blow_target_top
		renderer.weather_storm_slab_beta = _slab_target_beta
		renderer.weather_storm_slab_bottom_m = _slab_target_bottom
		renderer.weather_storm_slab_top_m = _slab_target_top
	return knobs


## Every frame: glide the blown slab's extinction and height toward the last reading's targets.
func smooth_blow(renderer: AtmosphereRenderer, delta: float) -> void:
	if not _blow_laid:
		return
	var k: float = 1.0 - exp(-delta * BLOW_GLIDE_RATE)
	renderer.weather_blow_beta = lerpf(renderer.weather_blow_beta, _blow_target_beta, k)
	renderer.weather_blow_bottom_m = lerpf(renderer.weather_blow_bottom_m, _blow_target_bottom, k)
	renderer.weather_blow_top_m = lerpf(renderer.weather_blow_top_m, _blow_target_top, k)
	renderer.weather_storm_slab_beta = lerpf(renderer.weather_storm_slab_beta, _slab_target_beta, k)
	renderer.weather_storm_slab_bottom_m = lerpf(renderer.weather_storm_slab_bottom_m, _slab_target_bottom, k)
	renderer.weather_storm_slab_top_m = lerpf(renderer.weather_storm_slab_top_m, _slab_target_top, k)


## Every frame: carry the noise with the wind, keep its frame the planet's, and hand the layer the
## camera's height, the local up and the light. The offset is the camera's position in the planet's
## frame plus the air's travel, wrapped in double precision so the float32 shader never sees more than
## DUST_WRAP_M.
func animate_dust(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D, delta: float) -> void:
	if _dust_density <= 0.0 or camera == null:
		if _dust_sent:
			renderer.set_dust_param(&"dust_density", 0.0)
			_dust_sent = false
		return
	_dust_sent = true
	if _noise == null:
		_noise = _make_noise()
		renderer.set_dust_param(&"dust_noise", _noise)
	var to_planet: Basis = planet.global_basis.orthonormalized().inverse()
	var wind_planet: Vector3 = to_planet * _dust_wind
	# The streaks' direction, smoothed: it turns over seconds, never in a frame.
	if wind_planet.length() > 0.1:
		var target: Vector3 = wind_planet.normalized()
		_wind_dir = target if _wind_dir.is_zero_approx() \
				else _wind_dir.lerp(target, clampf(delta * WIND_DIR_RATE, 0.0, 1.0)).normalized()
	var w: Vector3 = _wind_dir if not _wind_dir.is_zero_approx() else Vector3.RIGHT
	var cam_planet: Vector3 = to_planet * (camera.global_position - planet.global_position)
	# The noise is anchored near the player (re-anchored past ANCHOR_RESET_M, rarely): the stretched
	# coordinates stay a few km long, and a turn of the wind moves the pattern by millimetres.
	if _anchor_set == false or cam_planet.distance_to(_anchor) > ANCHOR_RESET_M:
		_anchor = cam_planet
		_anchor_set = true
	var squeeze: float = 1.0 - 1.0 / DUST_STRETCH
	var cam_q: Vector3 = _stretch(cam_planet - _anchor, w, squeeze)
	# The air's travel, in the stretched space, wrapped to each scale's period as it goes.
	var travel: Vector3 = _stretch(-wind_planet * delta, w, squeeze)
	var period_c: float = DUST_NOISE_SCALE
	var period_f: float = DUST_NOISE_SCALE * FINE_SCALE
	_scroll = _wrap(_scroll + travel, period_c)
	_scroll_fine = _wrap(_scroll_fine + travel * FINE_GUST_SPEED, period_f)
	var offset: Vector3 = _wrap(cam_q + _scroll, period_c)
	renderer.set_dust_param(&"dust_wind_dir", w)
	renderer.set_dust_param(&"dust_stretch", DUST_STRETCH)
	renderer.set_dust_param(&"dust_noise_scale", DUST_NOISE_SCALE)
	var up: Vector3 = (camera.global_position - planet.global_position).normalized()
	var height: float = 1.7
	if planet.planet_data != null:
		var dir: Vector3 = planet.local_dir_of(camera.global_position)
		if not dir.is_zero_approx():
			var surface: float = planet.planet_data.crack_aware_surface_dist(dir)
			height = camera.global_position.distance_to(planet.global_position) - surface
			_lay_ground(renderer, planet, dir * surface, cam_planet)
	renderer.set_dust_param(&"dust_frame", to_planet)
	renderer.set_dust_param(&"dust_offset", offset)
	renderer.set_dust_param(&"dust_offset_fine", _wrap(cam_q + _scroll_fine, period_f))
	renderer.set_dust_param(&"dust_up", up)
	renderer.set_dust_param(&"dust_cam_height", height)
	var masks: Array[Projection] = renderer.weather_masks.masks_for(camera.global_position) \
			if renderer.weather_masks != null and not WeatherBench.no_masks else ([] as Array[Projection])
	renderer.set_dust_param(&"dust_mask_count", masks.size())
	if not masks.is_empty():
		renderer.set_dust_param(&"dust_mask", masks)
	if _probe_on:
		_probe_light(renderer)
	if _probe_on:
		_probe(_scroll, wind_planet, masks.size(), height, delta)
	_push_dust_light(renderer, up)


## The light on the dust, near layer and storm volume alike: the sun's beam as it arrives (dimmed by
## the storm overhead, renderer.transmittance_at) and an ambient term. Under a storm the dust takes
## the beam away but, corundum barely absorbing, gives it back diffuse: the two-stream estimate of
## the light through a conservative layer, 1 / (1 + 3/4 (1 - g) τ) (60 % at τ 2.6), minus the
## direct beam, is the diffuse part. Lit by the dimmed beam alone, a storm's inside read black.
func _push_dust_light(renderer: AtmosphereRenderer, up: Vector3) -> void:
	if not is_instance_valid(renderer.sun):
		return
	var c: Color = renderer.sun.light_color * renderer.sun.light_energy
	var sin_e: float = maxf(renderer.sun.star_direction.dot(up), 0.02)
	var direct: float = exp(-_tau_above / sin_e) if _tau_above > 0.0 else 1.0
	var total: float = 1.0 / (1.0 + 0.75 * (1.0 - DUST_G) * _tau_above)
	var diffuse: float = maxf(total - direct, 0.0)
	var beam := Vector3(c.r, c.g, c.b)
	var unstormed: Vector3 = beam / maxf(direct, 1e-3)  # the beam before the storm took its share
	renderer.set_dust_param(&"dust_sun", beam)
	renderer.set_dust_param(&"dust_sun_free", unstormed)
	# The sky slab's multiple scattering: its saturated radiance becomes the diffuse light under the
	# column over the eye, T / pi (a Lambertian sky), over the dust's albedo.
	renderer.weather_storm_slab_ms = total / (PI * BLOW_ALBEDO_MAX)
	renderer.set_dust_param(&"dust_ambient", unstormed * (0.22 * direct + DUST_DIFFUSE_SHARE * diffuse)
			+ Vector3(0.03, 0.035, 0.045))
	renderer.set_dust_param(&"dust_sun_dir", renderer.sun.star_direction)


## A dust storm (WeatherSystem.state() form) [param ahead_m] along the ground from [param dir]
## (planet-local unit direction of the camera) toward [param forward] (planet-local, any length), on a
## planet of [param radius].
static func test_storm(dir: Vector3, forward: Vector3, ahead_m: float, radius: float) -> Dictionary:
	var flat: Vector3 = forward - dir * forward.dot(dir)
	if flat.length_squared() < 1e-12:
		flat = dir.cross(Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
	var at: Vector3 = dir.rotated(dir.cross(flat).normalized(), ahead_m / radius)
	var ll: Vector2 = HEALPix.vec2lonlat(at)
	return {
		"id": "debug-dust-storm", "name": "test storm", "kind": WeatherSampler.KIND_DUST_STORM,
		"lon": ll.x, "lat": ll.y, "sigma_m": TEST_STORM_RADIUS_M * 0.5, "intensity": 1.0,
		"pressure_anomaly_pa": -300.0, "wind_peak": 15.0, "dust_tau": TEST_STORM_TAU,
		"precipitation_mm_h": 0.0, "humidity": 0.0,
	}


## Is the storm volume drawing [param planet]'s storms? Not on an airless body (no air to lift the
## dust or hold it up: a cloud falls back on ballistic arcs), not without a climate, nor when switched
## off (client.ini debug_no_storm_volume, the GPU bench): then the veil's old knob carries the storm.
func storm_volume_on(planet: Planet) -> bool:
	if planet == null or _no_storm_volume or WeatherBench.no_storm:
		return false
	var climate: ClimateProfile = planet.climate_profile()
	return climate != null and climate.has_atmosphere


## Every frame, whatever the wind here (a storm far away shows in a calm): keep the storm grid around
## the camera and hand the far volume its frame, the camera's place on it, and its bounds.
func animate_storm(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D) -> void:
	if camera == null or planet.planet_data == null or not storm_volume_on(planet):
		renderer.set_dust_param(&"storm_on", 0)
		return
	if planet.get_instance_id() != _storm_planet:
		_storm = StormField.new()
		_storm_planet = planet.get_instance_id()
	var dir: Vector3 = planet.local_dir_of(camera.global_position)
	if dir.is_zero_approx():
		return
	var surface: float = planet.planet_data.crack_aware_surface_dist(dir)
	_cam_height = camera.global_position.distance_to(planet.global_position) - surface
	if _test_storm_km > 0.0 and not _test_storm_laid:
		_test_storm_laid = true
		var to_planet_basis: Basis = planet.global_basis.orthonormalized().inverse()
		planet.debug_weather_systems.append(test_storm(dir, to_planet_basis * -camera.global_basis.z,
				_test_storm_km * 1000.0, planet.planet_data.radius))
		print("[WeatherSky] client.ini debug_dust_storm_km: a test dust storm laid %.0f km ahead" % _test_storm_km)
	var job: Callable = StormField.dust_sampler(planet.climate_profile(), planet.weather_systems(),
			planet.weather_override.duplicate())
	if _noise == null:
		_noise = _make_noise()
		renderer.set_dust_param(&"dust_noise", _noise)
	var data: PlanetData = planet.planet_data
	var colour: Callable = func(d: Vector3) -> Color: return GroundLook.colour_at(data, d, BLOW_FALLBACK_COLOUR)
	if _storm.update(dir * surface, data.crack_aware_surface_dist, job, Time.get_ticks_msec() * 0.001,
			StormField.BUDGET_MS, colour):
		renderer.set_dust_param(&"storm_albedo", _storm.albedo_texture)
		# The colour noise's period, and the anchor in periods (double precision here): the pattern
		# belongs to the planet, it does not jump when the grid is laid again 50 km on.
		renderer.set_dust_param(&"storm_colour_noise_m", STORM_COLOUR_NOISE_M)
		renderer.set_dust_param(&"storm_noise_offset", _wrap(_storm.anchor / STORM_COLOUR_NOISE_M, 1.0))
		renderer.set_dust_param(&"storm_lid_noise_a_m", STORM_LID_NOISE_A_M)
		renderer.set_dust_param(&"storm_lid_noise_b_m", STORM_LID_NOISE_B_M)
		renderer.set_dust_param(&"storm_lid_noise_c_m", STORM_LID_NOISE_C_M)
		renderer.set_dust_param(&"storm_dust", _storm.dust_texture)
		renderer.set_dust_param(&"storm_ground", _storm.ground_texture)
		renderer.set_dust_param(&"storm_east", _storm.east)
		renderer.set_dust_param(&"storm_north", _storm.north)
		renderer.set_dust_param(&"storm_up", _storm.up)
		renderer.set_dust_param(&"storm_half", StormField.half_m())
		renderer.set_dust_param(&"storm_radius", _storm.anchor.length())
		renderer.set_dust_param(&"storm_ground_top", _storm.ground_top_m)
		renderer.set_dust_param(&"storm_beta_max", _storm.beta_max)
	if not _storm.ready:
		renderer.set_dust_param(&"storm_on", 0)
		return
	var to_planet: Basis = planet.global_basis.orthonormalized().inverse()
	renderer.set_dust_param(&"storm_frame", to_planet)
	var cam_rel: Vector3 = to_planet * (camera.global_position - planet.global_position) - _storm.anchor
	renderer.set_dust_param(&"storm_cam", cam_rel)
	# The billows move: carried by the wind (a share of the ground wind, the storm's top drifting) and
	# boiling in place (the noise slides slowly along the local up, domes swelling and sinking). Kept in
	# double precision here and wrapped to each scale's period: no jump, ever.
	var dt: float = renderer.get_process_delta_time()
	_storm_drift += to_planet * planet.wind_world_at(camera.global_position) * dt * STORM_DRIFT_SHARE
	_storm_churn += dt * STORM_CHURN_M_S
	var moved: Vector3 = _storm.anchor - _storm_drift + _storm.up * _storm_churn
	renderer.set_dust_param(&"storm_lid_offset_a", _wrap(moved / STORM_LID_NOISE_A_M, 1.0))
	renderer.set_dust_param(&"storm_lid_offset_b", _wrap(moved / STORM_LID_NOISE_B_M, 1.0))
	renderer.set_dust_param(&"storm_lid_offset_c", _wrap(moved / STORM_LID_NOISE_C_M, 1.0))
	# The storm over the eye, measured like the volume draws it: up to its lid (the smoothed ground plus
	# DUST_LAYER_M), not DUST_LAYER_M over the ground underfoot. On a peak that rises out of the storm
	# there is none overhead, as seen from above; in a valley it fills deeper. Light, sky slab and the
	# volume then agree (a peak clear from the air read dark once landed on, 2026-10-08).
	var r_a: float = _storm.anchor.length()
	var lid: float = _storm.lid_at(cam_rel)
	_ground_elev_m = surface - planet.planet_data.radius
	if not is_nan(lid):
		_column_m = lid + WeatherSampler.DUST_LAYER_M - StormField.altitude_over_anchor(cam_rel, _storm.up, r_a)
		_lid_top_elev_m = r_a + lid + WeatherSampler.DUST_LAYER_M - planet.planet_data.radius
		_lid_known = true
	renderer.set_dust_param(&"storm_on", 1 if _storm.beta_max > 1e-7 else 0)
	# The volume's light, also in a calm here (the near layer, which sets it too, may be off).
	_push_dust_light(renderer, (camera.global_position - planet.global_position).normalized())


## Keep the ground grid around [param ground_point] (planet-local, the ground under the camera) and
## hand the layer the camera's place on it. A grid laid on another planet is dropped first.
func _lay_ground(renderer: AtmosphereRenderer, planet: Planet, ground_point: Vector3, cam_planet: Vector3) -> void:
	if planet.get_instance_id() != _ground_planet:
		_ground = DustGround.new()
		_ground_planet = planet.get_instance_id()
		renderer.set_dust_param(&"dust_ground_on", 0)
	if _ground.update(ground_point, planet.planet_data.crack_aware_surface_dist):
		renderer.set_dust_param(&"dust_ground", _ground.texture)
		renderer.set_dust_param(&"dust_ground_east", _ground.east)
		renderer.set_dust_param(&"dust_ground_north", _ground.north)
		renderer.set_dust_param(&"dust_ground_up", _ground.up)
		renderer.set_dust_param(&"dust_ground_half", DustGround.half_m())
		renderer.set_dust_param(&"dust_ground_on", 1)
	if not _ground.ready:
		return
	# Both relative to the anchor, computed here in double precision: small numbers for the shader.
	renderer.set_dust_param(&"dust_ground_cam", cam_planet - _ground.anchor)
	# How far the grid's highest ground stands over the ground under the camera: the layer reaches
	# that much higher than the flat test says (a hill ahead holds dust over the camera's own level).
	var under_cam: float = (ground_point - _ground.anchor).dot(_ground.up)
	renderer.set_dust_param(&"dust_ground_lift", maxf(0.0, _ground.top_m - under_cam))


## The probe's light side: the sun's energy and colour (> 2 %), the veil's two knobs, the blown slab.
func _probe_light(renderer: AtmosphereRenderer) -> void:
	var sun_e: float = renderer.sun.light_energy if is_instance_valid(renderer.sun) else 0.0
	var sun_c: Color = renderer.sun.light_color if is_instance_valid(renderer.sun) else Color.BLACK
	var now := [sun_e, sun_c, renderer.weather_haze_scale, renderer.weather_haze_floor_m, renderer.weather_blow_beta]
	if not _probe_light_last.is_empty():
		var why: PackedStringArray = []
		var e0: float = _probe_light_last[0]
		if absf(sun_e - e0) > 0.02 * maxf(e0, 1e-4):
			why.append("sun energy %.4f -> %.4f" % [e0, sun_e])
		var c0: Color = _probe_light_last[1]
		if absf(c0.r - sun_c.r) + absf(c0.g - sun_c.g) + absf(c0.b - sun_c.b) > 0.02:
			why.append("sun colour %s -> %s" % [c0, sun_c])
		if _probe_light_last[2] != now[2] or _probe_light_last[3] != now[3]:
			why.append("veil knobs %s,%s -> %s,%s" % [_probe_light_last[2], _probe_light_last[3], now[2], now[3]])
		if absf(float(_probe_light_last[4]) - float(now[4])) > 1e-6:
			why.append("blown slab %.5f -> %.5f" % [_probe_light_last[4], now[4]])
		if not why.is_empty():
			print("[DustProbe] f%d t%.2f LIGHT %s" % [Engine.get_frames_drawn(), Time.get_ticks_msec() * 0.001, " | ".join(why)])
	_probe_light_last = now


## The dust probe: logs, with the frame and the clock, each jump of what the layer is sent — the
## density (> 5 % in a frame), the wind's direction (> 2°), the noise offset (off its expected travel
## by > 0.5 m), the march's start, the number of masked buildings, the camera height (> 1 m) — and a
## summary line every 5 s. A jump that matches the "jump" the eye sees names its cause.
func _probe(offset: Vector3, wind: Vector3, masks: int, height: float, delta: float) -> void:
	var now: Dictionary = {"density": _dust_density, "wind": wind, "offset": offset, "masks": masks,
			"height": height, "start": _probe_start}
	var why: PackedStringArray = []
	if not _probe_last.is_empty():
		var last: Dictionary = _probe_last
		var d0: float = float(last["density"])
		if absf(_dust_density - d0) > 0.05 * maxf(d0, 1e-5):
			why.append("density %.5f -> %.5f" % [d0, _dust_density])
		var w0: Vector3 = last["wind"]
		if w0.length() > 0.1 and wind.length() > 0.1 and rad_to_deg(w0.angle_to(wind)) > 2.0:
			why.append("wind dir %.1f deg" % rad_to_deg(w0.angle_to(wind)))
		var travel: Vector3 = offset - (last["offset"] as Vector3)
		var expected: Vector3 = _stretch(-wind * delta, _wind_dir, 1.0 - 1.0 / DUST_STRETCH)
		var wrapped: bool = absf(travel.x) > DUST_NOISE_SCALE * 0.5 or absf(travel.y) > DUST_NOISE_SCALE * 0.5 \
				or absf(travel.z) > DUST_NOISE_SCALE * 0.5
		if not wrapped and (travel - expected).length() > 0.5:
			why.append("offset jumped %.2f m (moved %s, wind expects %s)" % [(travel - expected).length(), travel, expected])
		if int(last["masks"]) != masks:
			why.append("masks %d -> %d" % [int(last["masks"]), masks])
		if absf(float(last["height"]) - height) > 1.0:
			why.append("camera height %.1f -> %.1f m" % [float(last["height"]), height])
		if float(last["start"]) != _probe_start:
			why.append("start %.0f -> %.0f m" % [float(last["start"]), _probe_start])
	if not why.is_empty():
		print("[DustProbe] f%d t%.2f %s" % [Engine.get_frames_drawn(), Time.get_ticks_msec() * 0.001, " | ".join(why)])
	var ms: int = Time.get_ticks_msec()
	if ms - _probe_summary_at > 5000:
		_probe_summary_at = ms
		print("[DustProbe] ground grid %s, last build %.1f ms of queries for %d cells" % [
			"ready" if _ground.ready else "building", _ground.last_build_ms, DustGround.SIZE * DustGround.SIZE])
		print("[DustProbe] storm grid %s, ground %.0f ms for %d cells, strongest storm %.4f /m (visibility %.0f m), over the eye τ %.2f" % [
			"ready" if _storm.ready else "building", _storm.last_ground_ms, StormField.SIZE * StormField.SIZE,
			_storm.beta_max, 3.912 / maxf(_storm.beta_max, 1e-9), _tau_above])
		print("[DustProbe] summary density %.5f (vis %.0f m) wind %.1f m/s masks %d height %.1f m start %.0f m" % [
			_dust_density, 3.912 / maxf(_dust_density, 1e-6), wind.length(), masks, height, _probe_start])
	_probe_last = now


## [param v] with its part along [param w] shrunk by [param squeeze]: the streaks' stretch.
static func _stretch(v: Vector3, w: Vector3, squeeze: float) -> Vector3:
	return v - w * v.dot(w) * squeeze


## Each component of [param v] wrapped into [0, period): the noise repeats every period, so the
## pattern is the same and the numbers stay small for the float32 shader.
static func _wrap(v: Vector3, period: float) -> Vector3:
	return Vector3(fposmod(v.x, period), fposmod(v.y, period), fposmod(v.z, period))


## A seamless 3D noise for the layer's gusts: NOISE_TEXELS a side, NOISE_CELLS features across, three
## octaves (generated on a worker by the engine; the layer shows once it is ready).
static func _make_noise() -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = NOISE_CELLS / float(NOISE_TEXELS)
	noise.fractal_octaves = 3
	var tex := NoiseTexture3D.new()
	tex.width = NOISE_TEXELS
	tex.height = NOISE_TEXELS
	tex.depth = NOISE_TEXELS
	tex.seamless = true
	tex.noise = noise
	return tex


## The blown slab's grey extinction (1/m) for a ground lifted [param lifted] (0..1,
## StormDust.saltation_rate): β = 3.912 / BLOW_VISIBILITY_FULL_M × lifted^BLOW_POWER (Koschmieder). 0 without lift.
static func blow_extinction(lifted: float) -> float:
	if lifted <= 0.0:
		return 0.0
	return 3.912 / BLOW_VISIBILITY_FULL_M * pow(clampf(lifted, 0.0, 1.0), BLOW_POWER)


## The slab's single-scattering albedo from the colour of the ground it is made of: the colour scaled
## so its brightest channel is BLOW_ALBEDO_MAX (mineral dust absorbs a little of everything, and more of
## what the ground does not reflect). A black or unknown ground gives the fallback.
static func blow_albedo_of(ground: Color) -> Vector3:
	var top: float = maxf(ground.r, maxf(ground.g, ground.b))
	if top <= 1e-6:
		return blow_albedo_of(BLOW_FALLBACK_COLOUR)
	return Vector3(ground.r, ground.g, ground.b) / top * BLOW_ALBEDO_MAX


## The two knobs for a storm dust optical depth [param dust_tau] over [param profile]'s veil,
## quantised: [scale, floor_m]. Pure, so the quantisation is testable.
static func knobs_for(profile: AtmosphereProfile, dust_tau: float) -> Array:
	if profile == null or dust_tau <= 1e-4:
		return [1.0, -1.0]
	var tau0: float = veil_optical_depth(profile)
	var raw_scale: float = 1.0 + dust_tau / maxf(tau0, 1e-3)
	var scale: float = pow(2.0, roundf(log(raw_scale) / log(2.0) / SCALE_STEP_LOG2) * SCALE_STEP_LOG2)
	var floor_m: float = -1.0
	if profile.haze_top > 0.0:
		var down: float = clampf(dust_tau / FLOOR_FULL_TAU, 0.0, 1.0)
		floor_m = roundf(lerpf(profile.haze_bottom, 0.0, down) / FLOOR_STEP_M) * FLOOR_STEP_M
	return [scale, floor_m]


## Vertical optical depth of the profile's own veil: |β_mie| × the slab's thickness (its integral
## is exactly that, whatever the falloff), or |β_mie| × scale height for an exponential haze.
static func veil_optical_depth(profile: AtmosphereProfile) -> float:
	var beta: float = profile.mie_beta.length() / sqrt(3.0)
	if profile.haze_top > 0.0:
		return beta * (profile.haze_top - profile.haze_bottom)
	return beta * profile.mie_scale_height


## How many times the knobs changed (so a test can count the table refills a ramp causes).
func refills() -> int:
	return _refills
