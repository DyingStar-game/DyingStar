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
const BLOW_FALLBACK_COLOUR: Color = Color(0.86, 0.74, 0.56)

var _last_read_at: float = -INF
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
	var ground: float = planet.elevation_of(observer_world_pos)
	renderer.weather_blow_bottom_m = ground - BLOW_BELOW_M
	renderer.weather_blow_top_m = ground + BLOW_ABOVE_M
	return knobs


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
