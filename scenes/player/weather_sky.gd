class_name WeatherSky
extends RefCounted
## The dust the wind blows off the ground around the eye: a layer near the ground, ray-marched by
## aerial_perspective.gdshader (dust_layer.gdshaderinc), dense at the ground and thinning upward, in
## streaks stretched along the wind that stream past. Client side, owned by AtmosphereRenderer.
##
## Everything it knows of the weather comes through Planet.weather_at / wind_world_at (WeatherSource):
## the wind and the ground's lift threshold give the dust lifted (DustLift), the dust's optical depth
## (a storm, none with UniformWeather) adds to it. Swap the planet's weather source and the layer
## follows, nothing to change here.

## How often the weather is read, seconds.
const REFRESH_S: float = 0.5
## The near layer's density: the visibility (m) a full blow (twice the ground's lift threshold) brings
## the plains down to — Koschmieder, β = 3.912 / V — and how the density rises to it with the lift.
const BLOW_VISIBILITY_FULL_M: float = 400.0
const BLOW_POWER: float = 1.5
## A storm's dust_tau is spread over this column (m) from the ground: its extinction near the eye.
const STORM_COLUMN_M: float = 1000.0
## What the blown dust reflects at most (its brightest channel), and the colour it takes when the
## ground under the observer has none to give (a pale ochre, the corundum plains).
const BLOW_ALBEDO_MAX: float = 0.92
const BLOW_FALLBACK_COLOUR: Color = Color(0.86, 0.74, 0.56)
## The near layer belongs to an eye on or near the ground: none under it (god mode through the
## terrain drew the whole screen dust-grey), whole from the ground up, gone past NEAR_LAYER_GONE_M
## over it (a wrong ground under a fast flight laid it round the eye in EVA).
const NEAR_LAYER_FULL_M: float = 80.0
const NEAR_LAYER_GONE_M: float = 300.0
## The near layer's e-folding height over the ground (m) and how far it is marched (m). 6 m over 300 m
## read as nothing at all (2026-10-09); 25 m thick and 1 km long, it veils the far relief and the
## horizon the way a blowing day does. Within the ground grid (DustGround.half_m).
const NEAR_LAYER_HEIGHT_M: float = 25.0
const NEAR_LAYER_RANGE_M: float = 1000.0
## The far dust (dust_layer.gdshaderinc dust_far): a layer lying on the real ground out to FAR_RANGE_M
## (m, plus the eye's height), FAR_HEIGHT_M thick, of FAR_SHARE of the near layer's density whatever the
## eye's height, in banks FAR_NOISE_SCALE (m) across. It sets the relief in planes (the far plains and
## valleys sink into the dust, the slopes rise out of it) and lies on the land seen from above (EVA).
## Its ground: a coarse wide grid, FAR_CELL_M cells (24 km across), rebuilt every FAR_REBUILD_M, built
## within FAR_BUDGET_MS a frame. FAR_SHARE 0 = no far dust.
const FAR_RANGE_M: float = 6000.0
const FAR_SHARE: float = 0.6
const FAR_HEIGHT_M: float = 60.0
const FAR_NOISE_SCALE: float = 20000.0
const FAR_CELL_M: float = 192.0
const FAR_REBUILD_M: float = 1500.0
const FAR_BUDGET_MS: float = 1.0
## How much brighter the dust glows in a lamp's beam than its density alone gives (dust_lamp_gain): an
## IMAGE choice, not physics: at the plains' visibility (km) a real beam is barely seen, only the ground
## it lights. 1 = physical (the first look, liked: the gusts streaming through the beam, 2026-10-10).
const LAMP_GAIN: float = 1.0
## Seated in a vehicle, the march starts this far out (m): the cab stays clear, its windows show the
## dust outside.
const CAB_CLEAR_M: float = 8.0
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
## The real ground around the camera the layer lies on (DustGround), the far dust's coarse wide one,
## and the planet they were laid on.
var _ground: DustGround = DustGround.new()
var _far_ground: DustGround = DustGround.new(FAR_CELL_M, FAR_REBUILD_M)
var _ground_planet: int = 0
## The far dust's banks drifting with the wind, wrapped to FAR_NOISE_SCALE.
var _far_scroll: Vector3 = Vector3.ZERO
## client.ini debug_no_dust_layer: the layer off (its cost and its look).
var _no_dust_layer: bool = ClientConfig.get_bool("debug_no_dust_layer", false)


## Read the weather at [param observer_world_pos] on [param planet] (every REFRESH_S) and set the
## layer's density, colour and start on [param renderer].
func update(renderer: AtmosphereRenderer, planet: Planet, observer_world_pos: Vector3) -> void:
	var now: float = Time.get_ticks_msec() * 0.001
	if now - _last_read_at < REFRESH_S:
		return
	_last_read_at = now
	var sample: Dictionary = planet.weather_at(observer_world_pos)
	var lifted: float = DustLift.ground_lift(float(sample.get("wind_speed_m_s", 0.0)),
			float(sample.get("lift_threshold_m_s", 0.0)))
	_dust_density = 0.0 if _no_dust_layer \
			else density_for(lifted, float(sample.get("dust_tau", 0.0)))
	_dust_wind = planet.wind_world_at(observer_world_pos)
	var ground_dir: Vector3 = planet.local_dir_of(observer_world_pos)
	var ground_colour: Color = GroundLook.at(planet.planet_data, ground_dir, BLOW_FALLBACK_COLOUR).color \
			if not ground_dir.is_zero_approx() else BLOW_FALLBACK_COLOUR
	renderer.set_dust_param(&"dust_albedo", blow_albedo_of(ground_colour))
	# Inside a building the masks keep the room clear; seated, the march starts past the cab.
	var boxed: bool = renderer.weather_masks != null and renderer.weather_masks.inside(observer_world_pos)
	var seated: bool = is_instance_valid(renderer.player) and is_instance_valid(renderer.player.get("_seat_node"))
	renderer.set_dust_param(&"dust_start", CAB_CLEAR_M if seated and not boxed else 0.0)
	renderer.set_dust_param(&"dust_height", NEAR_LAYER_HEIGHT_M)
	renderer.set_dust_param(&"dust_range", NEAR_LAYER_RANGE_M)
	renderer.set_dust_param(&"dust_far_height", FAR_HEIGHT_M)
	renderer.set_dust_param(&"dust_lamp_gain", LAMP_GAIN)
	renderer.set_dust_param(&"dust_far_noise_scale", FAR_NOISE_SCALE)


## Every frame: carry the noise with the wind, keep its frame the planet's, and hand the layer the
## camera's height, the local up and the light. The offset is the camera's position in the planet's
## frame plus the air's travel, wrapped in double precision so the float32 shader never sees more than
## a noise period.
func animate_dust(renderer: AtmosphereRenderer, planet: Planet, camera: Camera3D, delta: float) -> void:
	if _dust_density <= 0.0 or camera == null:
		if _dust_sent:
			renderer.set_dust_param(&"dust_density", 0.0)
			renderer.set_dust_param(&"dust_far_density", 0.0)
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
	if not _anchor_set or cam_planet.distance_to(_anchor) > ANCHOR_RESET_M:
		_anchor = cam_planet
		_anchor_set = true
	var squeeze: float = 1.0 - 1.0 / DUST_STRETCH
	var cam_q: Vector3 = _stretch(cam_planet - _anchor, w, squeeze)
	# The air's travel, in the stretched space, wrapped to each scale's period as it goes.
	var travel: Vector3 = _stretch(-wind_planet * delta, w, squeeze)
	var period_c: float = DUST_NOISE_SCALE
	var period_f: float = DUST_NOISE_SCALE * FINE_SCALE
	_scroll = wrap_to_period(_scroll + travel, period_c)
	_scroll_fine = wrap_to_period(_scroll_fine + travel * FINE_GUST_SPEED, period_f)
	_far_scroll = wrap_to_period(_far_scroll - wind_planet * delta, FAR_NOISE_SCALE)
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
			_lay_grounds(renderer, planet, dir * surface, cam_planet)
	renderer.set_dust_param(&"dust_frame", to_planet)
	renderer.set_dust_param(&"dust_offset", wrap_to_period(cam_q + _scroll, period_c))
	renderer.set_dust_param(&"dust_offset_fine", wrap_to_period(cam_q + _scroll_fine, period_f))
	renderer.set_dust_param(&"dust_up", up)
	renderer.set_dust_param(&"dust_cam_height", height)
	var share: float = near_layer_share(height)
	renderer.set_dust_param(&"dust_density", _dust_density * share)
	_push_far(renderer, cam_planet, height, share)
	var masks: Array[Projection] = renderer.weather_masks.masks_for(camera.global_position) \
			if renderer.weather_masks != null else ([] as Array[Projection])
	renderer.set_dust_param(&"dust_mask_count", masks.size())
	if not masks.is_empty():
		renderer.set_dust_param(&"dust_mask", masks)
	DustLight.push(renderer, up)


## The far dust: its density whatever the eye's height, its reach (longer by the eye's height, so the
## land below is still covered from EVA), where it starts (past the near layer while that is seen,
## from the eye once it is gone) and its banks' place on the planet (wrapped in double precision).
func _push_far(renderer: AtmosphereRenderer, cam_planet: Vector3, height: float, share: float) -> void:
	renderer.set_dust_param(&"dust_far_density", _dust_density * FAR_SHARE)
	renderer.set_dust_param(&"dust_far_range", FAR_RANGE_M + maxf(height, 0.0))
	renderer.set_dust_param(&"dust_far_start", lerpf(0.0, NEAR_LAYER_RANGE_M * 0.7, share))
	renderer.set_dust_param(&"dust_far_fade", lerpf(1.0, NEAR_LAYER_RANGE_M * 0.3, share))
	renderer.set_dust_param(&"dust_far_noise_offset", wrap_to_period(cam_planet + _far_scroll, FAR_NOISE_SCALE))


## Keep both ground grids around [param ground_point] (planet-local, the ground under the camera) and
## hand the layer the camera's place on them. Grids laid on another planet are dropped first.
func _lay_grounds(renderer: AtmosphereRenderer, planet: Planet, ground_point: Vector3, cam_planet: Vector3) -> void:
	if planet.get_instance_id() != _ground_planet:
		_ground = DustGround.new()
		_far_ground = DustGround.new(FAR_CELL_M, FAR_REBUILD_M)
		_ground_planet = planet.get_instance_id()
		renderer.set_dust_param(&"dust_ground_on", 0)
		renderer.set_dust_param(&"dust_far_ground_on", 0)
	var radius: Callable = planet.planet_data.crack_aware_surface_dist
	_lay_grid(renderer, _ground, "dust_ground", ground_point, cam_planet, radius, DustGround.BUDGET_MS)
	_lay_grid(renderer, _far_ground, "dust_far_ground", ground_point, cam_planet, radius, FAR_BUDGET_MS)
	if _far_ground.ready:
		# The far grid's highest ground over the ground under the camera: where the far dust ends going up.
		var under_far: float = (ground_point - _far_ground.anchor).dot(_far_ground.up)
		renderer.set_dust_param(&"dust_far_ground_lift", maxf(0.0, _far_ground.top_m - under_far))
	if _ground.ready:
		# How far the near grid's highest ground stands over the ground under the camera: the layer
		# reaches that much higher than the flat test says (a hill ahead holds dust over the eye's level).
		var under_cam: float = (ground_point - _ground.anchor).dot(_ground.up)
		renderer.set_dust_param(&"dust_ground_lift", maxf(0.0, _ground.top_m - under_cam))


## Keep [param grid] around [param ground_point] and hand the layer its uniforms, named [param prefix]_*:
## the texture and frame when a new grid is swapped in, the camera relative to its anchor every frame
## (computed here in double precision: small numbers for the shader).
static func _lay_grid(renderer: AtmosphereRenderer, grid: DustGround, prefix: String, ground_point: Vector3,
		cam_planet: Vector3, radius: Callable, budget_ms: float) -> void:
	if grid.update(ground_point, radius, budget_ms):
		renderer.set_dust_param(prefix, grid.texture)
		renderer.set_dust_param(prefix + "_east", grid.east)
		renderer.set_dust_param(prefix + "_north", grid.north)
		renderer.set_dust_param(prefix + "_up", grid.up)
		renderer.set_dust_param(prefix + "_half", grid.half())
		renderer.set_dust_param(prefix + "_on", 1)
	if grid.ready:
		renderer.set_dust_param(prefix + "_cam", cam_planet - grid.anchor)


## The layer's extinction at the ground (1/m): the dust the wind lifts ([param lifted], 0..1, DustLift)
## plus a storm's [param dust_tau] spread over STORM_COLUMN_M.
static func density_for(lifted: float, dust_tau: float) -> float:
	return blow_extinction(lifted) + maxf(dust_tau, 0.0) / STORM_COLUMN_M


## [param v] with its part along [param w] shrunk by [param squeeze]: the streaks' stretch.
static func _stretch(v: Vector3, w: Vector3, squeeze: float) -> Vector3:
	return v - w * v.dot(w) * squeeze


## Each component of [param v] wrapped into [0, period): the noise repeats every period, so the
## pattern is the same and the numbers stay small for the float32 shader.
static func wrap_to_period(v: Vector3, period: float) -> Vector3:
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


## How much of the near layer an eye [param height_m] over the ground sees (see NEAR_LAYER_FULL_M).
static func near_layer_share(height_m: float) -> float:
	return smoothstep(-2.0, 0.5, height_m) * (1.0 - smoothstep(NEAR_LAYER_FULL_M, NEAR_LAYER_GONE_M, height_m))


## The near layer's grey extinction (1/m) for a ground lifted [param lifted] (0..1, DustLift):
## β = 3.912 / BLOW_VISIBILITY_FULL_M × lifted^BLOW_POWER (Koschmieder). 0 without lift.
static func blow_extinction(lifted: float) -> float:
	if lifted <= 0.0:
		return 0.0
	return 3.912 / BLOW_VISIBILITY_FULL_M * pow(clampf(lifted, 0.0, 1.0), BLOW_POWER)


## The dust's single-scattering albedo from the colour of the ground it is made of: the colour scaled
## so its brightest channel is BLOW_ALBEDO_MAX (mineral dust absorbs a little of everything, and more of
## what the ground does not reflect). A black or unknown ground gives the fallback.
static func blow_albedo_of(ground: Color) -> Vector3:
	var top: float = maxf(ground.r, maxf(ground.g, ground.b))
	if top <= 1e-6:
		return blow_albedo_of(BLOW_FALLBACK_COLOUR)
	return Vector3(ground.r, ground.g, ground.b) / top * BLOW_ALBEDO_MAX
