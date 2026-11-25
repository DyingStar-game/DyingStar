class_name DustSea
extends RefCounted
## The corundum dust sea of Sandbox as the renderer draws it (dust_sea.gdshaderinc, sea_*), and the light
## it leaves under it. Client side, owned by AtmosphereRenderer, every frame on a body whose atmosphere
## profile has a corundum slab (haze_top > haze_bottom); off with client.ini debug_no_dust_sea.
##
## Calibrated on the atmosphere model's white (opaque) sea (services weather, Nova-Atmo, sea optical depth
## 14): visibility ~1 km inside, dust down to the ground in the basins (a column of ~15 there, 23 % of the
## sunlight reaching the ground, all of it diffuse), a billowed top near 3 300 m, the plateaus over it in
## the clear (a thin dust of optical depth ~0.4 above). One uniform extinction from the ground to the top
## gives all of these at once with the two-stream estimate DustLight already uses (1 / (1 + 3/4 (1-g) tau)).
## When the service publishes its field (WeatherField, through Planet.weather_at), the sea's thickness
## follows its dust_tau around the eye; without it, the calibrated default.
##
## While it is drawn, the profile's slab is replaced (AtmosphereRenderer._haze_values) by the thin dust
## over the sea, the sun's beam is dimmed by the sea over the eye (transmittance_at), and the world's
## ambient light becomes the overcast's (overcast()).
##
## Its numbers are the model's Sandbox settings (services repository, weather/data/atmosphere/sandbox.toml,
## section [sea]: z_base_m 500, z_top_m 3500, optical_depth 14) as the model's runs turn them into a
## profile (mean top ~3 250 m, basin column ~15.5, visibility ~1 km). Kept here for now; they belong in
## the generated AtmosphereProfile (a follow-up).

## The mean top of the sea (m over the reference sphere: the model's 3 250 m mean profile, the billows
## reach ±BILLOW_M around it), the lowest ground a ray is marched down to (m), and the base the
## worldbuilding gives the sea (m): the basins under it hold dust down to their floor all the same (the
## model's columns reach the ground), so the base only caps the ground the light bounces on.
const SEA_TOP_M: float = 3300.0
const FLOOR_M: float = -3000.0
const BASE_M: float = 500.0
## The visibility inside the sea (m) at the calibrated default (Koschmieder: extinction 3.912 / V), and
## the model's sea optical depth it stands for. 1 km over a basin column of 3.8 km is the model's ~15.
const VISIBILITY_M: float = 1000.0
const DEFAULT_TAU: float = 14.0
## The top denser than the inside (an IMAGE choice: the domes read as shapes, not as a soft fog), by
## TOP_BOOST over its last TOP_SCALE_M: an optical depth of 0.9 more, against 15.
const TOP_BOOST: float = 2.0
const TOP_SCALE_M: float = 150.0
## The thin dust over the sea, as the profile's slab from the top up THIN_M, edges THIN_FALLOFF_M soft. The
## model gives ~0.4 over the plateaus; at 0.4 over 3 km the single-scattered sky over a plateau was a thick
## warm haze with a huge aureole, five times as bright as the clear sky (2026-11-25): a lower, thinner dust
## (an IMAGE choice until the sky has multiple scattering). At 0.2 over 1.5 km the aureole was still large and
## milky 500 m over the top: 0.1 over 800 m, with grains scattering more sharply forward (THIN_G: a small,
## bright aureole, the rest of the sky clear). 90 % of the beam straight through, 98 % in all.
const THIN_TAU: float = 0.1
const THIN_M: float = 800.0
const THIN_G: float = 0.85
const THIN_FALLOFF_M: float = 300.0
## The weather's say: the sea's thickness factor from the field's dust_tau over the column under the eye
## (only where that column is at least MIN_COLUMN_M deep: over a plateau the field's small τ says nothing
## of the sea below), within [FACTOR_MIN, FACTOR_MAX], glided to at FACTOR_RATE (1/s). Read every REFRESH_S.
## A field whose τ is under FIELD_NO_SEA of the calibrated column comes from a model run without the white
## sea (the service's older settings: a sea of τ 0.4): it cannot speak for this sea, and is not listened to.
## Taken at its word it thinned the sea to the 0.4 floor, 2.5 km of visibility in a basin (2026-11-25).
const MIN_COLUMN_M: float = 800.0
const FACTOR_MIN: float = 0.7
const FIELD_NO_SEA: float = 0.25
const FACTOR_MAX: float = 2.5
const FACTOR_RATE: float = 0.1
const REFRESH_S: float = 1.0
## The billowed top: its amplitude (m) and the periods (m) of its four scales (the noises hold
## NOISE_CELLS features a period: swells of ~3 km, domes of ~850 m, puffs of ~250 m, a grain of ~65 m).
const BILLOW_M: float = 250.0
const BILLOW_A_M: float = 40000.0
const BILLOW_B_M: float = 12000.0
const BILLOW_C_M: float = 3500.0
const BILLOW_D_M: float = 900.0
## How the billows move: this share of the wind at the sea's top carries them, and the noise slides
## along the local up at CHURN_M_S (m/s) so the domes swell and sink.
const DRIFT_SHARE: float = 0.6
const CHURN_M_S: float = 4.0
## The colour: white grains, tinted by the rock under them (DustSeaMap) by ROCK_TINT inside the sea (the
## fog of a basin takes its rock's hue) and EDGE_TINT at its top (from above the sea is WHITE, bitogno
## 2026-11-25: at 0.5 it read cream-ochre); patches of brighter and darker dust on COLOUR_NOISE_M.
const WHITE: Color = Color(0.96, 0.95, 0.93)
const ROCK_TINT: float = 0.3
const EDGE_TINT: float = 0.12
const COLOUR_NOISE_M: float = 9000.0
## The body of a dust wall or devil over the sea: this share of the ground's dust colour, the rest the sea's
## white. A wall looks like the ground it rides over (the user, 2026-11-25: at the sea's 0.3 a wall over
## golden-ochre ground read grey-white); under the sea it takes the sea's own palette (ROCK_TINT).
const BODY_GROUND_SHARE: float = 0.7
## A wall's or a devil's dust from the ground's colour (wall_dust_of): WALL_SATURATION of the ground's hue
## kept (the near dust and the sea keep less, WeatherSky.BLOW_SATURATION: a fine haze), and brightened only
## WALL_BRIGHTEN of the way to the haze's (a thick dust cloud is nearly as dark as its ground: at the haze's
## brightness and saturation, every wall read pale grey whatever it ran over, 2026-11-25).
const WALL_SATURATION: float = 0.8
const WALL_BRIGHTEN: float = 0.4
## The multiply scattered light's weight (1 = the two-stream radiance), the sky's own glow over the sea
## (share of the star's beam), and the two-stream factor 3/4 (1 - g) for corundum (DustLight.G).
const MS_GAIN: float = 0.85
const AMBIENT_SHARE: float = 0.03
## The direct beam's weight over the dust's phase, and the light the hollows between the domes keep (0..1):
## the domes' relief, which at a grazing angle from a plateau's edge read flat (IMAGE choices, 2026-11-25).
const DIRECT_GAIN: float = 1.5
const CREASE_FLOOR: float = 0.4
const TWO_STREAM: float = 0.225  # 0.75 * (1 - 0.7), DustLight.G; dust_sea.gdshaderinc SEA_TWO_STREAM
## The sea's optical depth over the eye at which the overcast takes over the world's ambient light:
## none under UNDER_FROM, all of it from UNDER_FULL.
const UNDER_FROM: float = 0.3
const UNDER_FULL: float = 3.0
## Under the sea, the eye adapts to the overcast (IMAGE choices, the light stays in proportion): its light
## goes NEUTRAL_LIGHT of the way from the star's orange (and the air's reddening) to a white of the same
## brightness (the eye's white balance; above the sea too: the sea is WHITE, as white as a dust wall's top),
## and everything the overcast lights, the fog and the land in it, is brighter (the eye opening): enough to
## bring the overcast at the eye to EYE_TARGET of the light a sunlit top gets, at most UNDER_GAIN_MAX times.
## Adapted to the eye's place: a basin's fog (23 %) and the bright inside near the top (85 %) both read as a
## pale overcast, not one dark and the other burnt out (the probe's numbers, 2026-11-25).
## At the bare physics the fog read a dark brown-ochre (2026-11-25).
const NEUTRAL_LIGHT: float = 0.85
const EYE_TARGET: float = 0.6
const UNDER_GAIN_MAX: float = 4.0
## How far the march looks inside the shell (m), its step budget against the atmosphere quality (view
## steps x STEPS_PER_VIEW_STEP within [STEPS_MIN, STEPS_MAX]), and rays per pixel against the altitude.
const FAR_M: float = 300000.0
const STEPS_PER_VIEW_STEP: float = 1.5
const STEPS_MIN: int = 16
const STEPS_MAX: int = 64
const RAYS_FROM_M: float = 50000.0
const RAYS_FULL_M: float = 500000.0
const RAYS_MAX: int = 2
## How far the camera goes (m) before the anchor (the reference sphere under it) is laid again.
const ANCHOR_RESET_M: float = 20000.0
## The noises: texels a side, features across one period.
const NOISE_TEXELS: int = 96
const NOISE_CELLS: float = 14.0

## The sea's thickness factor now (1 = the calibrated default).
var factor: float = 1.0

var _on: bool = false
var _no_sea: bool = ClientConfig.get_bool("debug_no_dust_sea", false)
var _factor_target: float = 1.0
var _map: DustSeaMap = DustSeaMap.new()
var _planet: int = 0
var _anchor: Vector3 = Vector3.ZERO
var _anchor_set: bool = false
var _drift: Vector3 = Vector3.ZERO
var _churn: float = 0.0
## The wind at the sea's top over the eye, in the planet's frame (m/s), read every REFRESH_S.
var _wind_planet: Vector3 = Vector3.ZERO
var _refresh_at: float = -INF
## The ground under the eye (m over the reference sphere) and the colour of its dust, read every REFRESH_S.
var _ground_m: float = 0.0
var _eye_dust: Color = WHITE
## The weather read at the eye at the last refresh (for the probe, DustSeaProbe).
var _last_sample: Dictionary = {}
## The sea's extinction around the eye now (1/m, veil_beta; 0 when it is not drawn), for what is drawn after
## the aerial pass and must sink into the fog all the same (WeatherPhenomena's dust walls and devils).
static var eye_veil: float = 0.0
## The rest of what those need to be lit as the sea is (dust_sea_light.gdshaderinc): its extinction now (1/m,
## 0 when it is not drawn), the ground its light bounces on (m), the star's light as the sea takes it (linear,
## light_colour × the sun's energy) and the eye's adaptation.
static var beta_now: float = 0.0
static var ground_now: float = BASE_M
static var sun_now: Vector3 = Vector3.ONE
static var gain_now: float = 1.0
static var eye_alt_now: float = 0.0
## The two noises (smooth, cellular), made once for the run on a worker thread.
static var _noises: Array = []
static var _noise_task: int = -1
static var _noise_layers: Array = []


## What the sea is now, for the probe (DustSeaProbe): its own state, not the shader's.
func probe() -> Dictionary:
	return {"on": _on, "wanted_off_by_client_ini": _no_sea, "factor": factor, "factor_target": _factor_target,
		"beta_per_m": beta(), "visibility_m": 3.912 / maxf(beta(), 1e-9), "top_m": SEA_TOP_M,
		"ground_under_eye_m": _ground_m, "eye_dust_colour": _eye_dust, "map_ready": _map.ready,
		"noises_ready": not _noises.is_empty(), "anchor": _anchor, "wind_at_top_planet": _wind_planet,
		"eye_veil": eye_veil, "gain_now": gain_now, "sun_now": sun_now,
		"weather_at_eye": _last_sample.duplicate()}


## Is the sea drawn this frame?
func is_on() -> bool:
	return _on


## Does [param profile] hold a dust sea (a corundum slab), and is it wanted?
func wanted(profile: AtmosphereProfile) -> bool:
	return not _no_sea and profile != null and profile.haze_top > profile.haze_bottom


## The extinction inside the sea now (1/m).
func beta() -> float:
	return 3.912 / VISIBILITY_M * factor


## Every frame: keep the anchor, the map and the weather's factor, hand the shader the sea's frame,
## heights, light and quality, and move the billows. Off (sea_on 0) when there is nothing to draw.
func animate(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D, delta: float) -> void:
	var profile: AtmosphereProfile = renderer.current_profile()
	if planet == null or camera == null or planet.planet_data == null or not wanted(profile) \
			or not is_instance_valid(renderer.sun) or not _noises_ready(renderer):
		off(renderer)
		return
	var data: PlanetData = planet.planet_data
	if planet.get_instance_id() != _planet:
		_planet = planet.get_instance_id()
		_map = DustSeaMap.new()
		_anchor_set = false
		_refresh_at = -INF
		renderer.set_dust_param(&"sea_map_on", 0)
	var colour: Callable = func(d: Vector3) -> Color: return GroundLook.colour_at(data, d, WeatherSky.BLOW_FALLBACK_COLOUR)
	if _map.update(colour):
		renderer.set_dust_param(&"sea_map", _map.texture)
		renderer.set_dust_param(&"sea_map_on", 1)
	var to_planet: Basis = planet.global_basis.orthonormalized().inverse()
	var cam_planet: Vector3 = to_planet * (camera.global_position - planet.global_position)
	if not _anchor_set or cam_planet.distance_to(_anchor) > ANCHOR_RESET_M:
		_anchor = cam_planet.normalized() * data.radius
		_anchor_set = true
		renderer.set_dust_param(&"sea_up", _anchor.normalized())
		renderer.set_dust_param(&"sea_radius", data.radius)
		renderer.set_dust_param(&"sea_noise_offset", WeatherSky.wrap_to_period(_anchor / COLOUR_NOISE_M, 1.0))
	var now: float = Time.get_ticks_msec() * 0.001
	if now >= _refresh_at:
		_refresh_at = now + REFRESH_S
		_refresh(planet, camera, to_planet)
	factor = move_toward(factor, _factor_target, FACTOR_RATE * delta)
	renderer.set_dust_param(&"sea_frame", to_planet)
	renderer.set_dust_param(&"sea_cam", cam_planet - _anchor)
	_push_sea(renderer)
	_push_view(renderer, camera, cam_planet.length() - data.radius)
	_push_light(renderer, profile)
	_move_billows(renderer, delta)
	_on = true
	renderer.set_dust_param(&"sea_on", 1)


## Nothing drawn: the renderer goes back to the profile's own slab and the sky's ambient.
func off(renderer: AtmosphereRenderer) -> void:
	if _on:
		renderer.set_dust_param(&"sea_on", 0)
		renderer.set_dust_param(&"dust_veil_beta", 0.0)
	_on = false
	eye_veil = 0.0
	beta_now = 0.0


## The sea's optical depth over [param altitude] (m over the reference sphere) up to its mean top.
func sea_tau_above(altitude: float) -> float:
	if not _on:
		return 0.0
	var b: float = beta()
	return b * maxf(SEA_TOP_M - altitude, 0.0) + (b * TOP_BOOST * TOP_SCALE_M if altitude < SEA_TOP_M else 0.0)


## All the dust's optical depth over [param altitude]: the sea's and the thin dust over it.
func tau_above(altitude: float) -> float:
	if not _on:
		return 0.0
	var thin: float = THIN_TAU * clampf((SEA_TOP_M + THIN_M - maxf(altitude, SEA_TOP_M)) / THIN_M, 0.0, 1.0)
	return sea_tau_above(altitude) + thin


## The sea's extinction around an eye at [param altitude] (1/m, the wind's dust behind it is veiled:
## dust_veil_beta), none over the top.
func veil_beta(altitude: float) -> float:
	if not _on:
		return 0.0
	return beta() * (1.0 - smoothstep(SEA_TOP_M - 100.0, SEA_TOP_M + 100.0, altitude))


## How much of the world's ambient light is the overcast's at [param altitude] (0..1).
func under_share(altitude: float) -> float:
	return smoothstep(UNDER_FROM, UNDER_FULL, sea_tau_above(altitude))


## The eye's adaptation at [param altitude]: 1 over the sea, under it what brings the overcast there to
## EYE_TARGET (see NEUTRAL_LIGHT), within [1, UNDER_GAIN_MAX].
func eye_gain(altitude: float) -> float:
	var adapted: float = clampf(EYE_TARGET / maxf(diffuse_share(altitude), 1e-3), 1.0, UNDER_GAIN_MAX)
	return lerpf(1.0, adapted, under_share(altitude))


## The share of a sunlit top's light the overcast gives at [param altitude] (the two-stream radiance over
## E mu0: 1 at the top, ~0.2 at the bottom of a basin).
func diffuse_share(altitude: float) -> float:
	var below: float = beta() * maxf(altitude - minf(_ground_m, BASE_M), 0.0)
	return (1.0 + TWO_STREAM * below) / (1.0 + TWO_STREAM * (below + sea_tau_above(altitude)))


## The star's colour [param star] as the sea's light (see NEUTRAL_LIGHT): the same brightness, paler.
static func light_colour(star: Color) -> Color:
	return star.lerp(Color(1.0, 1.0, 1.0) * star.get_luminance(), NEUTRAL_LIGHT)


## Hand [param material] (a shader with dust_sea_light.gdshaderinc) the sea as it is drawn now.
static func light_material(material: ShaderMaterial) -> void:
	material.set_shader_parameter("sea_beta", beta_now)
	material.set_shader_parameter("sea_top", SEA_TOP_M)
	material.set_shader_parameter("sea_ground", ground_now)
	material.set_shader_parameter("sea_sun", sun_now)
	material.set_shader_parameter("sea_gain", gain_now)
	material.set_shader_parameter("sea_eye_alt", eye_alt_now)
	material.set_shader_parameter("sea_white", Vector3(WHITE.r, WHITE.g, WHITE.b))
	material.set_shader_parameter("sea_rock_tint", ROCK_TINT)
	material.set_shader_parameter("body_ground_share", BODY_GROUND_SHARE)


## The share of the sunlight the ground at [param elevation] m gets under the sea (two-stream, at the
## calibrated default: ~0.2 in a basin, 1 over the top), for what the sun's heating of the ground drives.
static func ground_sun_share(elevation: float) -> float:
	if elevation >= SEA_TOP_M:
		return 1.0
	var tau: float = 3.912 / VISIBILITY_M * (SEA_TOP_M - elevation + TOP_BOOST * TOP_SCALE_M)
	return 1.0 / (1.0 + TWO_STREAM * tau)


## How much of a dust devil's strength the ground at [param elevation] m can drive under the sea: a devil is
## the ground's heat rising, and a basin under the opaque sea gets a fifth of the sun, all of it diffuse: none
## there, fewer and weaker on the slopes, all of them over the top (the user, 2026-11-25).
static func devil_share(elevation: float) -> float:
	return smoothstep(0.25, 0.9, ground_sun_share(elevation))


## The colour of a wall's or a devil's dust over a ground of colour [param ground] (see WALL_SATURATION).
static func wall_dust_of(ground: Color) -> Color:
	var top: float = maxf(ground.r, maxf(ground.g, ground.b))
	if top <= 1e-6:
		return wall_dust_of(WeatherSky.BLOW_FALLBACK_COLOUR)
	var hue := Vector3(ground.r, ground.g, ground.b) / top
	hue = Vector3.ONE.lerp(hue, WALL_SATURATION)
	var c := hue * lerpf(top, WeatherSky.BLOW_ALBEDO_MAX, WALL_BRIGHTEN)
	return Color(c.x, c.y, c.z)


## Does [param profile] hold the dust sea (whatever the client draws)?
static func has_sea(profile: AtmosphereProfile) -> bool:
	return profile != null and profile.haze_top > profile.haze_bottom


## The visibility (m) at [param elevation] m over the reference sphere of a body holding the sea
## (has_sea) with [param sample] the weather there: the sea's fog under its top; over it, the
## weather's dust without the climate's permanent haze (the sea replaces it) plus the thin dust over the sea.
## For the weather's readouts (Planet.weather_at): the sea is the planet's, whatever the weather source says.
static func visibility_at(elevation: float, sample: Dictionary) -> float:
	if elevation < SEA_TOP_M:
		return VISIBILITY_M
	var dust: float = maxf(float(sample.get("dust_tau", 0.0)) - float(sample.get("haze_tau", 0.0)), 0.0)
	var beta: float = dust / WeatherSampler.DUST_LAYER_M
	if elevation < SEA_TOP_M + THIN_M:
		beta += THIN_TAU / THIN_M
	return 3.912 / beta if beta > 1e-9 else WeatherSampler.NO_DUST_VISIBILITY_M


## The overcast's diffuse light at [param altitude] under a star [param sin_e] high, in the engine's
## units (an ambient colour): the two-stream radiance the shader lights the sea with,
## E mu0 (1 + 3/4 (1-g) tau_below) / (1 + 3/4 (1-g) tau_total), of the star's beam [param free] before
## the dust (DustLight.free_beam, of the star's light_colour), tinted like the dust around, as bright as the
## eye's adaptation makes it (eye_gain). A white ground under it returns what the sea around it shows: the
## land sinks into the fog without a seam.
func overcast(altitude: float, sin_e: float, free: Vector3) -> Color:
	var ms: float = maxf(sin_e, 0.0) * diffuse_share(altitude)
	var tint: Color = WHITE.lerp(_eye_dust, ROCK_TINT)
	var light: Vector3 = free * ms * MS_GAIN * eye_gain(altitude)
	return Color(light.x * tint.r, light.y * tint.g, light.z * tint.b)


## The share of the weather's [param sample] dust_tau that is NOT the sea (a storm's), for the wind's
## dust near the ground (WeatherSky): the field's τ is the whole column, sea included, and the climate's
## permanent haze (WeatherRelief.haze, "haze_tau": the old 500-3 500 m veil) is what the sea now draws.
func storm_tau(sample: Dictionary) -> float:
	var tau: float = maxf(float(sample.get("dust_tau", 0.0)), 0.0)
	if not _on:
		return tau
	tau = maxf(tau - float(sample.get("haze_tau", 0.0)), 0.0)
	if not bool(sample.get("weather_field", false)):
		return tau
	return maxf(tau - sea_tau_above(_ground_m), 0.0)


## The ground under the eye, its dust's colour, the wind at the sea's top, and the weather's thickness factor.
func _refresh(planet: Planet, camera: Camera3D, to_planet: Basis) -> void:
	var data: PlanetData = planet.planet_data
	var dir: Vector3 = planet.local_dir_of(camera.global_position)
	if dir.is_zero_approx():
		return
	_ground_m = data.crack_aware_surface_dist(dir) - data.radius
	var top: Vector3 = planet.global_position + planet.global_basis.orthonormalized() * dir * (data.radius + SEA_TOP_M)
	_wind_planet = to_planet * planet.wind_world_at(top)
	_eye_dust = _albedo_colour(GroundLook.colour_at(data, dir, WeatherSky.BLOW_FALLBACK_COLOUR))
	var sample: Dictionary = planet.weather_at(camera.global_position)
	_last_sample = sample
	var column_m: float = SEA_TOP_M - _ground_m
	if bool(sample.get("weather_field", false)) and column_m >= MIN_COLUMN_M:
		var calibrated: float = 3.912 / VISIBILITY_M * (column_m + TOP_BOOST * TOP_SCALE_M)
		var ratio: float = float(sample.get("dust_tau", 0.0)) / calibrated
		_factor_target = 1.0 if ratio < FIELD_NO_SEA else clampf(ratio, FACTOR_MIN, FACTOR_MAX)
	elif not bool(sample.get("weather_field", false)):
		_factor_target = 1.0


static func _albedo_colour(ground: Color) -> Color:
	var a: Vector3 = WeatherSky.blow_albedo_of(ground)
	return Color(a.x, a.y, a.z)


func _push_sea(renderer: AtmosphereRenderer) -> void:
	renderer.set_dust_param(&"sea_top", SEA_TOP_M)
	renderer.set_dust_param(&"sea_floor", FLOOR_M)
	renderer.set_dust_param(&"sea_beta", beta())
	renderer.set_dust_param(&"sea_ground", minf(_ground_m, BASE_M))
	renderer.set_dust_param(&"sea_top_boost", TOP_BOOST)
	renderer.set_dust_param(&"sea_top_scale", TOP_SCALE_M)
	renderer.set_dust_param(&"sea_billow_m", BILLOW_M)
	renderer.set_dust_param(&"sea_billow_a_m", BILLOW_A_M)
	renderer.set_dust_param(&"sea_billow_b_m", BILLOW_B_M)
	renderer.set_dust_param(&"sea_billow_c_m", BILLOW_C_M)
	renderer.set_dust_param(&"sea_billow_d_m", BILLOW_D_M)
	renderer.set_dust_param(&"sea_white", Vector3(WHITE.r, WHITE.g, WHITE.b))
	renderer.set_dust_param(&"sea_rock_tint", ROCK_TINT)
	renderer.set_dust_param(&"sea_edge_tint", EDGE_TINT)
	renderer.set_dust_param(&"sea_colour_noise_m", COLOUR_NOISE_M)
	renderer.set_dust_param(&"sea_ms_gain", MS_GAIN)
	renderer.set_dust_param(&"sea_direct_gain", DIRECT_GAIN)
	renderer.set_dust_param(&"sea_crease_floor", CREASE_FLOOR)
	renderer.set_dust_param(&"sea_neutral", NEUTRAL_LIGHT)
	eye_alt_now = renderer.altitude_above_sphere()
	eye_veil = veil_beta(eye_alt_now)
	renderer.set_dust_param(&"dust_veil_beta", eye_veil)
	gain_now = eye_gain(renderer.altitude_above_sphere())
	renderer.set_dust_param(&"sea_eye_gain", gain_now)
	beta_now = beta()
	ground_now = minf(_ground_m, BASE_M)


## The star's beam before the air (the shader reads the air over each sample), paler (light_colour), and
## the sky's glow.
func _push_light(renderer: AtmosphereRenderer, profile: AtmosphereProfile) -> void:
	var star: Color = light_colour(profile.star_color)
	var sun: Vector3 = Vector3(star.r, star.g, star.b) * renderer.sun.sun_energy
	sun_now = sun
	renderer.set_dust_param(&"sea_sun", sun)
	renderer.set_dust_param(&"sea_ambient", sun * AMBIENT_SHARE)


## The step budget from the atmosphere quality, rays per pixel, how far the march looks, and the angle
## one pixel spans (detail under a pixel is faded instead of sparkling).
func _push_view(renderer: AtmosphereRenderer, camera: Camera3D, altitude: float) -> void:
	renderer.set_dust_param(&"sea_steps", clampi(int(renderer.view_steps * STEPS_PER_VIEW_STEP), STEPS_MIN, STEPS_MAX))
	var share: float = clampf((altitude - RAYS_FROM_M) / (RAYS_FULL_M - RAYS_FROM_M), 0.0, 1.0)
	renderer.set_dust_param(&"sea_rays", 1 + int(round(share * float(RAYS_MAX - 1))))
	renderer.set_dust_param(&"sea_far", FAR_M)
	var height_px: float = maxf(camera.get_viewport().get_visible_rect().size.y, 1.0)
	renderer.set_dust_param(&"sea_pixel_rad", deg_to_rad(camera.fov) / height_px)


## The billows move: carried by the wind at the sea's top (a share of it) and boiling in place (the
## noise slides slowly along the local up). Kept in double precision here, wrapped to each period.
func _move_billows(renderer: AtmosphereRenderer, delta: float) -> void:
	_drift += _wind_planet * delta * DRIFT_SHARE
	_churn += delta * CHURN_M_S
	var moved: Vector3 = _anchor - _drift + _anchor.normalized() * _churn
	renderer.set_dust_param(&"sea_billow_offset_a", WeatherSky.wrap_to_period(moved / BILLOW_A_M, 1.0))
	renderer.set_dust_param(&"sea_billow_offset_b", WeatherSky.wrap_to_period(moved / BILLOW_B_M, 1.0))
	renderer.set_dust_param(&"sea_billow_offset_c", WeatherSky.wrap_to_period(moved / BILLOW_C_M, 1.0))
	renderer.set_dust_param(&"sea_billow_offset_d", WeatherSky.wrap_to_period(moved / BILLOW_D_M, 1.0))


## The two noises handed to [param renderer] once made (their making starts at the first ask).
func _noises_ready(renderer: AtmosphereRenderer) -> bool:
	if _noises.is_empty():
		if _noise_task < 0:
			_noise_task = WorkerThreadPool.add_task(func() -> void: _noise_layers = noise_layers(), false, "dust sea noise")
			return false
		if not WorkerThreadPool.is_task_completed(_noise_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_noise_task)
		for layers: Array in _noise_layers:
			var images: Array[Image] = []
			images.assign(layers)
			var texture := ImageTexture3D.new()
			texture.create(images[0].get_format(), NOISE_TEXELS, NOISE_TEXELS, NOISE_TEXELS, false, images)
			_noises.append(texture)
		_noise_layers = []
	if not _on:
		renderer.set_dust_param(&"sea_noise", _noises[0])
		renderer.set_dust_param(&"sea_worley", _noises[1])
	return true


## The layers of the two seamless noises, on any thread: a smooth one (three octaves) and a cellular one
## (the distance to the nearest cell, 0..1), NOISE_CELLS features a period each.
static func noise_layers() -> Array:
	var smooth := FastNoiseLite.new()
	smooth.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	smooth.frequency = NOISE_CELLS / float(NOISE_TEXELS)
	smooth.fractal_octaves = 3
	var cells := FastNoiseLite.new()
	cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	cells.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	cells.fractal_type = FastNoiseLite.FRACTAL_NONE
	cells.frequency = NOISE_CELLS / float(NOISE_TEXELS)
	return [smooth.get_seamless_image_3d(NOISE_TEXELS, NOISE_TEXELS, NOISE_TEXELS, false, 0.1, true),
			cells.get_seamless_image_3d(NOISE_TEXELS, NOISE_TEXELS, NOISE_TEXELS, false, 0.1, true)]
