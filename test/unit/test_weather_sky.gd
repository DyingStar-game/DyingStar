extends GutTest
## WeatherSky: the weather's two knobs on the veil (a factor on the Mie coefficients, a floor the
## slab comes down to), quantised so the transmittance table is refilled a few dozen times over a
## storm, not once per frame; and the CPU twin of the sky (AtmosphereProfile.transmittance_to_star)
## honouring the same knobs, so the star dims as the sky thickens.

const PROFILE := "res://scenes/planet/atmospheres/tarsis_3.tres"

var _profile : AtmosphereProfile = null


func before_all() -> void:
	_profile = load(PROFILE)


func test_no_dust_means_the_calibrated_veil() -> void:
	assert_eq(WeatherSky.knobs_for(_profile, 0.0), [1.0, -1.0])
	assert_eq(WeatherSky.knobs_for(null, 3.0), [1.0, -1.0], "no profile, no veil")


func test_the_scale_follows_the_storm_in_eighth_of_doublings() -> void:
	var tau0 : float = WeatherSky.veil_optical_depth(_profile)
	assert_almost_eq(tau0, 1.9037, 0.02, "Sandbox's veil: optical depth 1.90 (build_atmosphere_profiles)")
	var knobs : Array = WeatherSky.knobs_for(_profile, tau0)
	assert_almost_eq(knobs[0], 2.0, 1e-9, "as much storm dust as veil: twice the Mie")
	var raw : float = 1.0 + 0.37 / tau0
	var scale : float = WeatherSky.knobs_for(_profile, 0.37)[0]
	assert_true(absf(log(scale) / log(2.0) - log(raw) / log(2.0)) <= 0.0626, "within half a step of the raw value")
	var steps : float = log(scale) / log(2.0) / 0.125
	assert_almost_eq(steps, roundf(steps), 1e-6, "on the lattice of 2^(1/8)")


func test_the_floor_comes_down_to_the_ground_as_the_storm_thickens() -> void:
	assert_almost_eq(WeatherSky.knobs_for(_profile, 0.05)[1], 500.0, 1e-9, "a wisp: the slab stays at 500 m")
	assert_almost_eq(WeatherSky.knobs_for(_profile, 0.5)[1], 250.0, 1e-9, "half a storm: halfway down")
	assert_almost_eq(WeatherSky.knobs_for(_profile, 2.0)[1], 0.0, 1e-9, "a storm: on the ground")


func test_a_ramp_costs_a_few_dozen_refills_not_one_per_frame() -> void:
	var changes : int = 0
	var last : Array = WeatherSky.knobs_for(_profile, 0.0)
	for i in 600:  # a 5-minute ramp sampled every 0.5 s, from clear to visibility 100 m
		var tau : float = 130.0 * float(i) / 600.0
		var knobs : Array = WeatherSky.knobs_for(_profile, tau)
		if knobs != last:
			changes += 1
			last = knobs
	assert_between(changes, 20, 80, "refills over the ramp: %d" % changes)


func test_the_cpu_twin_honours_the_knobs() -> void:
	var clear : Color = _profile.transmittance_to_star(380.0, 0.5)
	var same : Color = _profile.transmittance_to_star(380.0, 0.5, 1.0, -1.0)
	assert_almost_eq(clear.r, same.r, 1e-9, "default knobs change nothing")
	var storm : Color = _profile.transmittance_to_star(380.0, 0.5, 8.0, -1.0)
	assert_lt(storm.get_luminance(), clear.get_luminance() * 0.2, "eight times the dust: far darker")
	# Under the slab (380 m < 500 m) the air is clear; lowering the floor to the ground puts dust overhead.
	var lowered : Color = _profile.transmittance_to_star(380.0, 0.5, 1.0, 0.0)
	assert_lt(lowered.get_luminance(), clear.get_luminance(), "a lowered floor adds dust on the way up")
	var above : Color = _profile.transmittance_to_star(6000.0, 0.9)
	var above_lowered : Color = _profile.transmittance_to_star(6000.0, 0.9, 1.0, 0.0)
	assert_almost_eq(above.get_luminance(), above_lowered.get_luminance(), 1e-6, "above the veil the floor is unseen")


func test_the_blown_slab_follows_the_lift_and_takes_the_grounds_colour() -> void:
	assert_eq(WeatherSky.blow_extinction(0.0), 0.0, "no lift: no slab")
	var full : float = WeatherSky.blow_extinction(1.0)
	assert_almost_eq(full, 3.912 / WeatherSky.BLOW_VISIBILITY_FULL_M, 1e-9, "a full blow: 400 m of visibility")
	assert_almost_eq(WeatherSky.blow_extinction(0.5) / full, pow(0.5, WeatherSky.BLOW_POWER), 1e-9, "rises as lift^1.5")
	assert_almost_eq(WeatherSky.blow_extinction(3.0), full, 1e-9, "capped at the full blow")
	var ochre : Vector3 = WeatherSky.blow_albedo_of(Color(0.8, 0.6, 0.4))
	assert_almost_eq(ochre.x, WeatherSky.BLOW_ALBEDO_MAX, 1e-9, "the brightest channel at the cap")
	assert_almost_eq(ochre.y / ochre.x, 0.75, 1e-6, "the ground's own hue kept (Color is float32)")
	assert_almost_eq(ochre.z / ochre.x, 0.5, 1e-6)
	assert_eq(WeatherSky.blow_albedo_of(Color.BLACK), WeatherSky.blow_albedo_of(WeatherSky.BLOW_FALLBACK_COLOUR),
			"no colour: the plains' ochre")


func test_the_near_layer_is_for_an_eye_near_the_ground() -> void:
	assert_eq(WeatherSky.near_layer_share(-400.0), 0.0, "under the terrain (god mode): none")
	assert_eq(WeatherSky.near_layer_share(1.7), 1.0, "standing: all of it")
	assert_eq(WeatherSky.near_layer_share(WeatherSky.NEAR_LAYER_FULL_M), 1.0, "low flight: all of it")
	assert_eq(WeatherSky.near_layer_share(WeatherSky.NEAR_LAYER_GONE_M), 0.0, "high in EVA: none")
