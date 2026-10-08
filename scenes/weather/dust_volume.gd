class_name DustVolume
extends RefCounted
## The regional dust volume as the renderer draws it (aerial_perspective.gdshader, storm_*): keeps the
## storm grid (StormField) around the camera, moves its billows, and measures the dust column over the
## eye the way the volume draws it, so the light around the eye agrees with what is seen. Every frame,
## whatever the wind here: a storm far away shows in a calm.
##
## Off on an airless body (no air to lift the dust or hold it up: a cloud falls back on ballistic arcs),
## without a climate, or when switched off (client.ini debug_no_storm_volume, the GPU bench): then the
## veil's old knob carries the storm (WeatherSky.update).

## The period (m) of the noise that twists the storm dust's colour boundaries.
const COLOUR_NOISE_M: float = 9000.0
## The periods (m) of the three noises that make a storm's top billow: the noise texture holds ~14
## features a period (WeatherSky.NOISE_CELLS), so domes of ~3 km, smaller ones of ~0.8 km and puffs of
## ~250 m.
const LID_NOISE_A_M: float = 40000.0
const LID_NOISE_B_M: float = 12000.0
const LID_NOISE_C_M: float = 3500.0
## How the billows move: this share of the ground wind carries them, and the noise slides along the
## local up at this speed (m/s) so the domes swell and sink.
const DRIFT_SHARE: float = 0.6
const CHURN_M_S: float = 4.0
## The test storm (client.ini debug_dust_storm_km): 60 km across, the τ of a strong real one.
const TEST_STORM_RADIUS_M: float = 60000.0
const TEST_STORM_TAU: float = 6.0

## What the eye's surroundings read (WeatherSky.update): the camera's height over the ground (m), the
## dust column over the eye up to the volume's lid (m, < 0 = over the lid), the lid's top and the ground
## under the camera (m over the planet's reference sphere), and whether the lid is known yet.
var cam_height: float = 1.7
var column_m: float = 0.0
var lid_top_elev_m: float = 0.0
var ground_elev_m: float = 0.0
var lid_known: bool = false
## The storm grid, and the planet's reference radius (m): for the dust probe.
var field: StormField = StormField.new()
var planet_radius: float = 0.0

var _planet: int = 0
var _drift: Vector3 = Vector3.ZERO
var _churn: float = 0.0
var _no_volume: bool = ClientConfig.get_bool("debug_no_storm_volume", false)
var _test_storm_km: float = ClientConfig.get_float("debug_dust_storm_km", 0.0)
var _test_storm_laid: bool = false


## Is the volume drawing [param planet]'s storms?
func on(planet: Planet) -> bool:
	if planet == null or _no_volume or WeatherBench.no_storm:
		return false
	var climate: ClimateProfile = planet.climate_profile()
	return climate != null and climate.has_atmosphere


## Every frame: keep the grid around [param camera], hand the volume its frame, the camera's place on
## it and its bounds, move the billows, measure the column over the eye, and light the dust under
## [param tau_above] (the dust's optical depth over the eye, WeatherSky.update).
func animate(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D, tau_above: float) -> void:
	if camera == null or planet.planet_data == null or not on(planet):
		renderer.set_dust_param(&"storm_on", 0)
		return
	if planet.get_instance_id() != _planet:
		field = StormField.new()
		_planet = planet.get_instance_id()
	var dir: Vector3 = planet.local_dir_of(camera.global_position)
	if dir.is_zero_approx():
		return
	var surface: float = planet.planet_data.crack_aware_surface_dist(dir)
	cam_height = camera.global_position.distance_to(planet.global_position) - surface
	if _test_storm_km > 0.0 and not _test_storm_laid:
		_test_storm_laid = true
		var to_planet_basis: Basis = planet.global_basis.orthonormalized().inverse()
		planet.debug_weather_systems.append(test_storm(dir, to_planet_basis * -camera.global_basis.z,
				_test_storm_km * 1000.0, planet.planet_data.radius))
		print("[WeatherSky] client.ini debug_dust_storm_km: a test dust storm laid %.0f km ahead" % _test_storm_km)
	var job: Callable = StormField.dust_sampler(planet.climate_profile(), planet.weather_systems(),
			planet.weather_override.duplicate())
	var data: PlanetData = planet.planet_data
	var colour: Callable = func(d: Vector3) -> Color: return GroundLook.colour_at(data, d, WeatherSky.BLOW_FALLBACK_COLOUR)
	if field.update(dir * surface, data.crack_aware_surface_dist, job, Time.get_ticks_msec() * 0.001,
			StormField.BUDGET_MS, colour):
		_push_grid(renderer)
	if not field.ready:
		renderer.set_dust_param(&"storm_on", 0)
		return
	var to_planet: Basis = planet.global_basis.orthonormalized().inverse()
	renderer.set_dust_param(&"storm_frame", to_planet)
	var cam_rel: Vector3 = to_planet * (camera.global_position - planet.global_position) - field.anchor
	renderer.set_dust_param(&"storm_cam", cam_rel)
	_move_billows(renderer, planet, camera, to_planet)
	_measure_column(planet, cam_rel, surface)
	renderer.set_dust_param(&"storm_on", 1 if field.beta_max > 1e-7 else 0)
	# The volume's light, also in a calm here (the near layer, which sets it too, may be off).
	DustLight.push(renderer, (camera.global_position - planet.global_position).normalized(), tau_above)


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


## A new grid (or a refresh of its dust): its textures, frame and bounds.
func _push_grid(renderer: AtmosphereRenderer) -> void:
	renderer.set_dust_param(&"storm_albedo", field.albedo_texture)
	# The colour noise's period, and the anchor in periods (double precision here): the pattern
	# belongs to the planet, it does not jump when the grid is laid again 50 km on.
	renderer.set_dust_param(&"storm_colour_noise_m", COLOUR_NOISE_M)
	renderer.set_dust_param(&"storm_noise_offset", WeatherSky.wrap_to_period(field.anchor / COLOUR_NOISE_M, 1.0))
	renderer.set_dust_param(&"storm_lid_noise_a_m", LID_NOISE_A_M)
	renderer.set_dust_param(&"storm_lid_noise_b_m", LID_NOISE_B_M)
	renderer.set_dust_param(&"storm_lid_noise_c_m", LID_NOISE_C_M)
	renderer.set_dust_param(&"storm_dust", field.dust_texture)
	renderer.set_dust_param(&"storm_ground", field.ground_texture)
	renderer.set_dust_param(&"storm_east", field.east)
	renderer.set_dust_param(&"storm_north", field.north)
	renderer.set_dust_param(&"storm_up", field.up)
	renderer.set_dust_param(&"storm_half", StormField.half_m())
	renderer.set_dust_param(&"storm_radius", field.anchor.length())
	renderer.set_dust_param(&"storm_ground_top", field.ground_top_m)
	renderer.set_dust_param(&"storm_beta_max", field.beta_max)


## The billows move: carried by the wind (a share of the ground wind, the storm's top drifting) and
## boiling in place (the noise slides slowly along the local up, domes swelling and sinking). Kept in
## double precision here and wrapped to each scale's period: no jump, ever.
func _move_billows(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D, to_planet: Basis) -> void:
	var dt: float = renderer.get_process_delta_time()
	_drift += to_planet * planet.wind_world_at(camera.global_position) * dt * DRIFT_SHARE
	_churn += dt * CHURN_M_S
	var moved: Vector3 = field.anchor - _drift + field.up * _churn
	renderer.set_dust_param(&"storm_lid_offset_a", WeatherSky.wrap_to_period(moved / LID_NOISE_A_M, 1.0))
	renderer.set_dust_param(&"storm_lid_offset_b", WeatherSky.wrap_to_period(moved / LID_NOISE_B_M, 1.0))
	renderer.set_dust_param(&"storm_lid_offset_c", WeatherSky.wrap_to_period(moved / LID_NOISE_C_M, 1.0))


## The dust over the eye, measured like the volume draws it: up to its lid (the smoothed ground plus
## DUST_LAYER_M), not DUST_LAYER_M over the ground underfoot. On a peak that rises out of the storm
## there is none overhead, as seen from above; in a valley it fills deeper. Light, sky slab and the
## volume then agree (a peak clear from the air read dark once landed on, 2026-10-08).
func _measure_column(planet: Planet, cam_rel: Vector3, surface: float) -> void:
	var r_a: float = field.anchor.length()
	var lid: float = field.lid_at(cam_rel)
	ground_elev_m = surface - planet.planet_data.radius
	planet_radius = planet.planet_data.radius
	if not is_nan(lid):
		column_m = lid + WeatherSampler.DUST_LAYER_M - StormField.altitude_over_anchor(cam_rel, field.up, r_a)
		lid_top_elev_m = r_a + lid + WeatherSampler.DUST_LAYER_M - planet.planet_data.radius
		lid_known = true
