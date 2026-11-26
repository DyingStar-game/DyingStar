extends GutTest
## The dust sea's calibration against the atmosphere model's white sea (services weather, Nova-Atmo):
## visibility ~1 km inside, the base at 500 m with a tenth of the dust under it, ~28 % of the sunlight
## reaching a basin floor (all of it diffuse), the plateaus over the top nearly in full sun (DustSea).


func _sea(ground_m: float) -> DustSea:
	var sea := DustSea.new()
	sea._on = true
	sea._ground_m = ground_m
	return sea


func test_the_inside_of_the_sea_is_a_one_kilometre_fog() -> void:
	assert_almost_eq(3.912 / _sea(-550.0).beta(), 1000.0, 1.0, "Koschmieder: 1 km at the calibrated default")


func test_a_basin_floor_has_the_models_column_and_light() -> void:
	var sea := _sea(-550.0)
	var tau := sea.sea_tau_above(-550.0)
	assert_between(tau, 12.0, 13.0, "the sea over its base, and a tenth of it under: ~12.5")
	assert_lt(exp(-tau), 1e-5, "no direct beam at the bottom of the sea")
	var light := sea.overcast(-550.0, 1.0, Vector3.ONE)
	var white_share := light.get_luminance() / (DustSea.MS_GAIN * sea.eye_gain(-550.0) * DustSea.WHITE.lerp(sea._eye_dust,
			DustSea.ROCK_TINT).get_luminance())
	assert_almost_eq(white_share, 0.28, 0.02, "~28 % of the sunlight reaches a basin floor, diffuse")


func test_under_the_base_the_dust_is_a_tenth_of_the_sea() -> void:
	assert_almost_eq(DustSea.depth_between(-500.0, 1500.0), 1000.0 + 0.1 * 1000.0, 1e-6,
			"full over the base, a tenth under it")
	assert_eq(DustSea.depth_between(1000.0, 2000.0), 1000.0, "all over the base")
	assert_almost_eq(DustSea.depth_between(-500.0, 0.0), 50.0, 1e-6, "all under the base")
	assert_eq(DustSea.base_share(2000.0), 1.0)
	assert_almost_eq(DustSea.base_share(-200.0), DustSea.BELOW_SHARE, 1e-6)
	assert_almost_eq(DustSea.visibility_at(-550.0, {}), DustSea.VISIBILITY_M / DustSea.BELOW_SHARE, 1.0,
			"a basin floor sees ten times further than the inside of the sea")


func test_a_plateau_over_the_top_is_in_the_sun() -> void:
	var sea := _sea(3600.0)
	assert_eq(sea.sea_tau_above(3600.0), 0.0, "no sea over a plateau above its top")
	var through := 1.0 / (1.0 + DustSea.TWO_STREAM * sea.tau_above(3600.0))
	assert_gt(through, 0.93, "the thin dust over the sea lets at least the model's 93 % of the sunlight through")
	assert_eq(sea.under_share(3600.0), 0.0, "the sky's ambient over the sea, not the overcast's")
	assert_eq(sea.under_share(-550.0), 1.0, "the overcast's under it")


func test_the_storm_share_leaves_the_sea_out_of_the_fields_dust() -> void:
	var sea := _sea(-550.0)
	var column := sea.sea_tau_above(-550.0)
	assert_almost_eq(sea.storm_tau({"dust_tau": column + 2.0, "weather_field": true}), 2.0, 1e-4,
			"the field's column holds the sea: only what is over it is a storm's")
	assert_eq(sea.storm_tau({"dust_tau": 2.0}), 2.0, "without the field, the systems' dust is all storm")


func test_the_readout_sees_the_sea_and_no_more_of_the_old_veil() -> void:
	assert_eq(DustSea.visibility_at(2000.0, {"dust_tau": 0.5, "haze_tau": 0.5}), DustSea.VISIBILITY_M,
			"under the top: the sea's fog")
	var over := DustSea.visibility_at(3900.0, {"dust_tau": 0.48, "haze_tau": 0.48})
	assert_almost_eq(over, 3.912 / (DustSea.THIN_TAU / DustSea.THIN_M), 1.0,
			"over it: the thin dust only, the climate's old veil (the sea now) left out")


func test_the_eye_adapts_to_the_overcast_where_it_is() -> void:
	var sea := _sea(-550.0)
	assert_almost_eq(sea.diffuse_share(-550.0) * sea.eye_gain(-550.0), DustSea.EYE_TARGET, 0.01,
			"a basin's fog brought to the target")
	assert_eq(sea.eye_gain(3600.0), 1.0, "no adaptation over the sea")
	assert_lte(sea.eye_gain(3000.0), sea.eye_gain(-550.0), "less near the top, where the overcast is brighter")


func test_devils_need_the_sun_the_sea_takes() -> void:
	assert_eq(DustSea.devil_share(-550.0), 0.0, "a basin under the opaque sea: no devil")
	assert_eq(DustSea.devil_share(3600.0), 1.0, "over the top: all of them")
	var slope := DustSea.devil_share(2500.0)
	assert_true(slope > 0.0 and slope < 1.0, "on the slopes: fewer and weaker")


func test_a_wall_keeps_the_colour_of_its_ground() -> void:
	var ochre := Color(0.5, 0.35, 0.15)
	var wall := DustSea.wall_dust_of(ochre)
	var haze := WeatherSky.blow_albedo_of(ochre)
	assert_lt(wall.b / wall.r, haze.z / haze.x, "more of the ground's hue than the fine haze")
	assert_lt(wall.r, haze.x, "and darker than the haze: a thick cloud of that dust")
	assert_gt(wall.r, ochre.r, "brighter than the ground itself")
