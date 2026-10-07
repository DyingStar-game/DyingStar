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
const BLOW_ABOVE_M: float = 25.0
## What the blown dust reflects at most (its brightest channel), and the colour it takes when the
## ground under the observer has none to give (a pale ochre, the corundum plains).
const BLOW_ALBEDO_MAX: float = 0.92
## The dust layer near the eye against the model's extinction (1 = the model's visibility at the
## ground), and the period (m) its noise offset is wrapped at.
const DUST_LAYER_STRENGTH: float = 1.0
const DUST_WRAP_M: float = 100000.0
## The fine gusts travel this much faster than the air (the coarse ones ride it).
const FINE_GUST_SPEED: float = 1.37
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
var _noise: NoiseTexture3D = null
## The dust probe (client.ini debug_dust_probe=true): what was sent to the layer last frame, to log
## every discontinuity of it. Off, it costs a bool test.
var _probe_start: float = 0.0
var _sheltered_start: bool = false
var _probe_on: bool = ClientConfig.get_bool("debug_dust_probe", false)
var _probe_last: Dictionary = {}
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
	var knobs: Array = knobs_for(profile, float(sample.get("dust_tau", 0.0)))
	if knobs[0] != renderer.weather_haze_scale or knobs[1] != renderer.weather_haze_floor_m:
		_refills += 1
	renderer.weather_haze_scale = knobs[0]
	renderer.weather_haze_floor_m = knobs[1]
	# The dust the wind blows off this ground: a thin Mie slab about the observer's own elevation.
	var climate: ClimateProfile = planet.climate_profile()
	var lifted: float = StormDust.saltation_rate(float(sample.get("wind_speed_m_s", 0.0)),
			climate.v10_threshold_m_s if climate != null else 0.0)
	renderer.weather_blow_beta = blow_extinction(lifted)
	var ground_dir: Vector3 = planet.local_dir_of(observer_world_pos)
	var ground_colour: Color = GroundLook.at(planet.planet_data, ground_dir, BLOW_FALLBACK_COLOUR).color \
			if not ground_dir.is_zero_approx() else BLOW_FALLBACK_COLOUR
	renderer.weather_blow_albedo = blow_albedo_of(ground_colour)
	# The wind's dust layer near the eye: the same extinction as the slab (the lift) plus the storm's.
	_dust_density = (blow_extinction(lifted) + float(sample.get("dust_tau", 0.0)) / WeatherSampler.DUST_LAYER_M) \
			* DUST_LAYER_STRENGTH
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
	var ground: float = planet.elevation_of(observer_world_pos)
	renderer.weather_blow_bottom_m = ground - BLOW_BELOW_M
	renderer.weather_blow_top_m = ground + BLOW_ABOVE_M
	return knobs


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
	_scroll -= wind_planet * delta
	_scroll_fine -= wind_planet * (delta * FINE_GUST_SPEED)
	var cam_planet: Vector3 = to_planet * (camera.global_position - planet.global_position)
	var offset: Vector3 = Vector3(fposmod(cam_planet.x + _scroll.x, DUST_WRAP_M),
			fposmod(cam_planet.y + _scroll.y, DUST_WRAP_M), fposmod(cam_planet.z + _scroll.z, DUST_WRAP_M))
	var up: Vector3 = (camera.global_position - planet.global_position).normalized()
	var height: float = 1.7
	if planet.planet_data != null:
		var dir: Vector3 = planet.local_dir_of(camera.global_position)
		if not dir.is_zero_approx():
			height = camera.global_position.distance_to(planet.global_position) \
					- planet.planet_data.crack_aware_surface_dist(dir)
	renderer.set_dust_param(&"dust_frame", to_planet)
	renderer.set_dust_param(&"dust_offset", offset)
	renderer.set_dust_param(&"dust_offset_fine", Vector3(fposmod(cam_planet.x + _scroll_fine.x, DUST_WRAP_M),
			fposmod(cam_planet.y + _scroll_fine.y, DUST_WRAP_M), fposmod(cam_planet.z + _scroll_fine.z, DUST_WRAP_M)))
	renderer.set_dust_param(&"dust_up", up)
	renderer.set_dust_param(&"dust_cam_height", height)
	var masks: Array[Projection] = renderer.weather_masks.masks_for(camera.global_position) \
			if renderer.weather_masks != null else ([] as Array[Projection])
	renderer.set_dust_param(&"dust_mask_count", masks.size())
	if not masks.is_empty():
		renderer.set_dust_param(&"dust_mask", masks)
	if _probe_on:
		_probe(offset, wind_planet, masks.size(), height, delta)
	if wind_planet.length() > 0.1:
		renderer.set_dust_param(&"dust_wind_dir", wind_planet.normalized())
	if is_instance_valid(renderer.sun):
		var c: Color = renderer.sun.light_color * renderer.sun.light_energy
		renderer.set_dust_param(&"dust_sun", Vector3(c.r, c.g, c.b))
		renderer.set_dust_param(&"dust_ambient", Vector3(c.r, c.g, c.b) * 0.22 + Vector3(0.03, 0.035, 0.045))
		renderer.set_dust_param(&"dust_sun_dir", renderer.sun.star_direction)


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
		var expected: Vector3 = -wind * delta
		if (travel - expected).length() > 0.5:
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
		print("[DustProbe] summary density %.5f (vis %.0f m) wind %.1f m/s masks %d height %.1f m start %.0f m" % [
			_dust_density, 3.912 / maxf(_dust_density, 1e-6), wind.length(), masks, height, _probe_start])
	_probe_last = now


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
