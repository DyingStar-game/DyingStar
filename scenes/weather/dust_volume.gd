class_name DustVolume
extends RefCounted
## The planetary cloud layer as the renderer draws it (cloud_layer.gdshaderinc, cloud_*): keeps the
## weather grid (StormField) and the planet map (CloudPlanetMap) around the camera, hands the layer its
## frame, the sea's heights, the view's quality and the light, moves the billows, and measures the dust
## column over the eye the way the layer draws it, so the light around the eye agrees with what is seen.
## Every frame, whatever the wind here: a storm far away shows in a calm.
##
## Off on an airless body (no air to lift the dust or hold it up: a cloud falls back on ballistic arcs),
## without a climate, or when switched off (client.ini debug_no_storm_volume, the GPU bench): then the
## veil's old knob carries the storm (WeatherSky.update).

## The sea's extinction over the veil's calibrated optical depth (1.9 on Sandbox, the planet's albedo).
## At 1 the ground showed through the sea from a plateau's edge 500 m over it: a τ of 1.9 lets 15 % of
## the light straight through, and half that under a high (DECK_MIN). Too transparent for a cloud sea
## (user, 2026-10-09): denser, as the dust gathers in the billows rather than spreading as the 1-D veil.
const SEA_OPACITY: float = 2.5
## The period (m) of the noise that varies the dust's colour within a cloud.
const COLOUR_NOISE_M: float = 9000.0
## The billowed top: its amplitude (m) and the periods (m) of its four scales — the noise texture holds
## ~14 features a period (WeatherSky.NOISE_CELLS): swells of ~3 km, domes of ~850 m, puffs of ~250 m and
## a cauliflower grain of ~65 m. A sea of clouds, not a storm: at ±1 300 m the sea stood as a wall over
## a cliff 100 m above its top (2026-10-08).
const BILLOW_M: float = 300.0
const BILLOW_A_M: float = 40000.0
const BILLOW_B_M: float = 12000.0
const BILLOW_C_M: float = 3500.0
const BILLOW_D_M: float = 900.0
## How the billows move: this share of the wind AT THE SEA'S TOP carries them (the wind there, not the
## one at the eye: WeatherLocal.height_factor), and the noise slides along the local up at this speed
## (m/s) so the domes swell and sink.
const DRIFT_SHARE: float = 0.6
const CHURN_M_S: float = 4.0
## The test storm (client.ini debug_dust_storm_km): 60 km across, the τ of a strong real one.
const TEST_STORM_RADIUS_M: float = 60000.0
const TEST_STORM_TAU: float = 6.0
## The period (m) of the noise that tears the cloud sea where the weather thins it (features ~14 km).
const COVER_M: float = 200000.0
## The cloud sea's dust is packed under its top, divided by e every DECK_SCALE_M below it: a dense,
## billowy top over a lighter haze, the profile's optical depth kept.
const DECK_SCALE_M: float = 400.0
## How far the march looks (m): a sea seen edge-on from inside it; the planet's curve ends most rays
## long before.
const FAR_M: float = 300000.0
## The march's longest step count follows the atmosphere quality (GraphicsOptions.ATMOSPHERE_STEPS'
## view steps, 16 to 48), this many per view step, within [STEPS_MIN, STEPS_MAX].
const STEPS_PER_VIEW_STEP: float = 1.5
const STEPS_MIN: int = 16
const STEPS_MAX: int = 64
## Rays averaged per pixel against the altitude over the reference sphere (m): one up to RAYS_FROM_M,
## RAYS_MAX from RAYS_FULL_M up. High up a step is a pixel wide and the jitter alone left a fine grain
## over the whole planet (2026-10-09); averaging a few rays costs little there, the shell is thin.
const RAYS_FROM_M: float = 50000.0
const RAYS_FULL_M: float = 500000.0
const RAYS_MAX: int = 2
## How much of the local grid (512 km) still counts against the altitude: all of it under
## GRID_FADE_FROM_M, none from GRID_FADE_TO_M up, where its disc (the local sea and storms against the
## calibrated sea past it) was a stamp on the planet.
const GRID_FADE_FROM_M: float = 150000.0
const GRID_FADE_TO_M: float = 350000.0

## What the eye's surroundings read (WeatherSky.update): the camera's height over the ground (m), the
## dust column over the eye up to the volume's lid (m, < 0 = over the lid), the lid's top and the ground
## under the camera (m over the planet's reference sphere), and whether the lid is known yet.
var cam_height: float = 1.7
var column_m: float = 0.0
var lid_top_elev_m: float = 0.0
var ground_elev_m: float = 0.0
var lid_known: bool = false
## The weather grid, the planet map, and the planet's reference radius (m): for the dust probe.
var field: StormField = StormField.new()
var map: CloudPlanetMap = CloudPlanetMap.new()
var planet_radius: float = 0.0

var _planet: int = 0
var _drift: Vector3 = Vector3.ZERO
var _churn: float = 0.0
## The sea's top over the reference sphere (m), where the billows' wind is read; NAN without a sea.
var _sea_top_m: float = NAN
var _no_volume: bool = ClientConfig.get_bool("debug_no_storm_volume", false)
var _test_storm_km: float = ClientConfig.get_float("debug_dust_storm_km", 0.0)
var _test_storm_laid: bool = false


## Is the volume drawing [param planet]'s clouds?
func on(planet: Planet) -> bool:
	if planet == null or _no_volume or WeatherBench.no_storm:
		return false
	var climate: ClimateProfile = planet.climate_profile()
	return climate != null and climate.has_atmosphere


## Every frame: keep the grid and the map around [param camera], hand the layer its frame, the camera's
## place on it and its bounds, move the billows, measure the column over the eye, and light the dust
## under [param tau_above] (the dust's optical depth over the eye, WeatherSky.update).
func animate(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D, tau_above: float) -> void:
	if camera == null or planet.planet_data == null or not on(planet):
		_off(renderer)
		return
	if planet.get_instance_id() != _planet:
		field = StormField.new()
		map = CloudPlanetMap.new()
		_planet = planet.get_instance_id()
		renderer.weather_ground_floor_m = 0.0  # another planet's ground: the reference sphere until its grid
		renderer.set_dust_param(&"cloud_planet_on", 0)
	var dir: Vector3 = planet.local_dir_of(camera.global_position)
	if dir.is_zero_approx():
		return
	var data: PlanetData = planet.planet_data
	var surface: float = data.crack_aware_surface_dist(dir)
	cam_height = camera.global_position.distance_to(planet.global_position) - surface
	if _test_storm_km > 0.0 and not _test_storm_laid:
		_test_storm_laid = true
		var to_planet_basis: Basis = planet.global_basis.orthonormalized().inverse()
		planet.debug_weather_systems.append(test_storm(dir, to_planet_basis * -camera.global_basis.z,
				_test_storm_km * 1000.0, data.radius))
		print("[WeatherSky] client.ini debug_dust_storm_km: a test dust storm laid %.0f km ahead" % _test_storm_km)
	var job: Callable = StormField.dust_sampler(planet.climate_profile(), planet.weather_systems(),
			planet.weather_override.duplicate())
	if field.update(dir * surface, data.crack_aware_surface_dist, job, Time.get_ticks_msec() * 0.001):
		_push_grid(renderer)
	var colour: Callable = func(d: Vector3) -> Color: return GroundLook.colour_at(data, d, WeatherSky.BLOW_FALLBACK_COLOUR)
	if map.update(colour):
		renderer.set_dust_param(&"cloud_planet", map.texture)
		renderer.set_dust_param(&"cloud_planet_on", 1)
	if not field.ready:
		_off(renderer)
		return
	renderer.weather_ground_floor_m = field.ground_low_m + field.anchor.length() - data.radius
	var to_planet: Basis = planet.global_basis.orthonormalized().inverse()
	renderer.set_dust_param(&"cloud_frame", to_planet)
	var cam_rel: Vector3 = to_planet * (camera.global_position - planet.global_position) - field.anchor
	renderer.set_dust_param(&"cloud_cam", cam_rel)
	_push_view(renderer, camera, camera.global_position.distance_to(planet.global_position) - data.radius)
	var sea: bool = _push_sea(renderer, planet)
	_move_billows(renderer, planet, camera, to_planet)
	_measure_column(planet, cam_rel, surface)
	renderer.set_dust_param(&"cloud_on", 1 if field.beta_max > 1e-7 or sea else 0)
	# The volume's light, also in a calm here (the near layer, which sets it too, may be off).
	DustLight.push(renderer, (camera.global_position - planet.global_position).normalized(), tau_above)


## Nothing drawn by the volume: the aerial pass takes the profile's 1-D veil back.
func _off(renderer: AtmosphereRenderer) -> void:
	renderer.set_dust_param(&"cloud_on", 0)
	renderer.weather_deck_volume = false


## The march's longest step count for [param view_steps] of atmosphere quality (see STEPS_PER_VIEW_STEP).
## Rays averaged per pixel at [param altitude] m over the reference sphere.
static func rays_for(altitude: float) -> int:
	var share: float = clampf((altitude - RAYS_FROM_M) / (RAYS_FULL_M - RAYS_FROM_M), 0.0, 1.0)
	return 1 + int(round(share * float(RAYS_MAX - 1)))


## The grid's weight at [param altitude] m over the reference sphere.
static func grid_fade(altitude: float) -> float:
	return 1.0 - smoothstep(GRID_FADE_FROM_M, GRID_FADE_TO_M, altitude)


static func steps_for(view_steps: int) -> int:
	return clampi(int(view_steps * STEPS_PER_VIEW_STEP), STEPS_MIN, STEPS_MAX)


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


## The view's quality: the step budget from the atmosphere quality, how far the march looks, and the
## angle one pixel spans (so detail under a pixel is faded instead of sparkling).
func _push_view(renderer: AtmosphereRenderer, camera: Camera3D, altitude: float) -> void:
	renderer.set_dust_param(&"cloud_steps", steps_for(renderer.view_steps))
	renderer.set_dust_param(&"cloud_rays", rays_for(altitude))
	renderer.set_dust_param(&"cloud_grid_fade", grid_fade(altitude))
	renderer.set_dust_param(&"cloud_far", FAR_M)
	var height_px: float = maxf(camera.get_viewport().get_visible_rect().size.y, 1.0)
	renderer.set_dust_param(&"cloud_pixel_rad", deg_to_rad(camera.fov) / height_px)


## The corundum cloud sea, the same dust as the storms: between the atmosphere profile's haze_bottom and
## haze_top (m over the reference sphere, raised by client.ini debug_corundum_lift_m), at the profile's
## calibrated optical depth (the veil's, 1.9 on Sandbox: the planet's 0.32 albedo). Its heights go to
## the shader over the grid anchor's sphere. True when it is drawn.
func _push_sea(renderer: AtmosphereRenderer, planet: Planet) -> bool:
	var profile: AtmosphereProfile = planet.planet_data.atmosphere_profile
	var on_now: bool = profile != null and profile.haze_top > profile.haze_bottom and not WeatherBench.no_veil
	renderer.weather_deck_volume = on_now
	renderer.set_dust_param(&"cloud_deck_on", 1 if on_now else 0)
	if not on_now:
		_sea_top_m = NAN
		return false
	var lift: float = renderer.corundum_lift_m
	var to_anchor: float = planet.planet_data.radius - field.anchor.length()
	_sea_top_m = profile.haze_top + lift
	renderer.set_dust_param(&"cloud_bottom", profile.haze_bottom + lift + to_anchor)
	renderer.set_dust_param(&"cloud_top", _sea_top_m + to_anchor)
	# The extinction at the top for the profile's τ through the whole exponential profile.
	var thickness: float = profile.haze_top - profile.haze_bottom
	var integral: float = DECK_SCALE_M * (1.0 - exp(-thickness / DECK_SCALE_M))
	renderer.set_dust_param(&"cloud_beta", SEA_OPACITY * WeatherSky.veil_optical_depth(profile) / integral)
	renderer.set_dust_param(&"cloud_scale_m", DECK_SCALE_M)
	renderer.set_dust_param(&"cloud_cover_m", COVER_M)
	return true


## A new grid (or a refresh of its dust): its textures, frame and bounds.
func _push_grid(renderer: AtmosphereRenderer) -> void:
	# The colour noise's period, and the anchor in periods (double precision here): the pattern
	# belongs to the planet, it does not jump when the grid is laid again 50 km on.
	renderer.set_dust_param(&"cloud_colour_noise_m", COLOUR_NOISE_M)
	renderer.set_dust_param(&"cloud_noise_offset", WeatherSky.wrap_to_period(field.anchor / COLOUR_NOISE_M, 1.0))
	renderer.set_dust_param(&"cloud_billow_m", BILLOW_M)
	renderer.set_dust_param(&"cloud_billow_a_m", BILLOW_A_M)
	renderer.set_dust_param(&"cloud_billow_b_m", BILLOW_B_M)
	renderer.set_dust_param(&"cloud_billow_c_m", BILLOW_C_M)
	renderer.set_dust_param(&"cloud_billow_d_m", BILLOW_D_M)
	renderer.set_dust_param(&"cloud_storm_depth", WeatherSampler.DUST_LAYER_M)
	renderer.set_dust_param(&"cloud_grid", field.dust_texture)
	renderer.set_dust_param(&"cloud_ground", field.ground_texture)
	renderer.set_dust_param(&"cloud_east", field.east)
	renderer.set_dust_param(&"cloud_north", field.north)
	renderer.set_dust_param(&"cloud_up", field.up)
	renderer.set_dust_param(&"cloud_half", StormField.half_m())
	renderer.set_dust_param(&"cloud_radius", field.anchor.length())
	renderer.set_dust_param(&"cloud_ground_top", field.ground_top_m)
	renderer.set_dust_param(&"cloud_ground_low", field.ground_lowest_m)
	renderer.set_dust_param(&"cloud_storm_max", field.beta_max)


## The billows move: carried by the wind at the sea's top (a share of it, the storm's top drifting) and
## boiling in place (the noise slides slowly along the local up, domes swelling and sinking). Kept in
## double precision here and wrapped to each scale's period: no jump, ever.
func _move_billows(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D, to_planet: Basis) -> void:
	var dt: float = renderer.get_process_delta_time()
	var up: Vector3 = (camera.global_position - planet.global_position).normalized()
	var at: Vector3 = camera.global_position if is_nan(_sea_top_m) \
			else planet.global_position + up * (planet.planet_data.radius + _sea_top_m)
	_drift += to_planet * planet.wind_world_at(at) * dt * DRIFT_SHARE
	_churn += dt * CHURN_M_S
	var moved: Vector3 = field.anchor - _drift + field.up * _churn
	renderer.set_dust_param(&"cloud_cover_offset", WeatherSky.wrap_to_period(moved / COVER_M, 1.0))
	renderer.set_dust_param(&"cloud_billow_offset_a", WeatherSky.wrap_to_period(moved / BILLOW_A_M, 1.0))
	renderer.set_dust_param(&"cloud_billow_offset_b", WeatherSky.wrap_to_period(moved / BILLOW_B_M, 1.0))
	renderer.set_dust_param(&"cloud_billow_offset_c", WeatherSky.wrap_to_period(moved / BILLOW_C_M, 1.0))
	renderer.set_dust_param(&"cloud_billow_offset_d", WeatherSky.wrap_to_period(moved / BILLOW_D_M, 1.0))


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
