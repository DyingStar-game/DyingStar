extends GutTest
## DustLight: the light through dust (the direct beam by Beer's law, the total by the two-stream
## estimate with the dust's absorption, never less than the direct), and the star's beam before any dust.


func test_clear_air_lets_everything_through() -> void:
	var light: Vector2 = DustLight.split(0.0, 0.5)
	assert_almost_eq(light.x, 1.0, 1e-9, "no dust: the whole beam")
	assert_almost_eq(light.y, 1.0, 1e-9)


func test_a_storm_takes_the_beam_and_gives_most_of_it_back_diffuse() -> void:
	var light: Vector2 = DustLight.split(2.6, 0.5)
	assert_almost_eq(light.x, exp(-2.6 / 0.5), 1e-9, "the direct beam: Beer along the slant")
	assert_almost_eq(light.y, 1.0 / (1.0 + 0.75 * 0.3 * 2.6), 1e-6, "the total: two-stream, ~63 %")
	assert_gt(light.y, light.x, "most of what reaches the ground is diffuse")


func test_a_star_on_the_horizon_gives_a_number() -> void:
	var light: Vector2 = DustLight.split(1.0, 0.0)
	assert_false(is_nan(light.x))
	assert_almost_eq(light.x, exp(-1.0 / 0.02), 1e-12, "the slant floored at 0.02")


func test_the_free_beam_crosses_the_air_but_no_dust() -> void:
	var noon: Vector3 = DustLight.free_beam(Color(1.0, 0.95, 0.9), 2.0, Color.WHITE)
	assert_almost_eq(noon.x, 2.0, 1e-9, "clear air at noon: the star at the engine's energy")
	var dawn: Vector3 = DustLight.free_beam(Color.WHITE, 2.0, Color(0.4, 0.15, 0.05))
	assert_gt(dawn.x, dawn.z * 4.0, "at sunrise the beam is orange and faint, not white")
	var night: Vector3 = DustLight.free_beam(Color.WHITE, 2.0, Color.BLACK)
	assert_eq(night, Vector3.ZERO, "the star under the horizon lights no dust")


func test_under_the_sea_the_dust_takes_the_overcast_not_the_orange_beam() -> void:
	var orange := Vector3(1.0, 0.5, 0.2)
	var white := Vector3(0.6, 0.6, 0.6)
	var overcast := Vector3(0.1, 0.1, 0.1)
	var over: Array[Vector3] = DustLight.under_sea(orange, orange * 0.3, white, overcast, 0.0)
	assert_eq(over[0], orange, "over the sea: the star's beam as it is")
	assert_eq(over[1], orange * 0.3)
	var under: Array[Vector3] = DustLight.under_sea(orange, orange * 0.3, white, overcast, 1.0)
	assert_eq(under[0], white, "deep in the sea: the whitened light")
	assert_eq(under[1], overcast, "and the sea's overcast as ambient, like the ground")
	var beyond: Array[Vector3] = DustLight.under_sea(orange, orange * 0.3, white, overcast, 3.0)
	assert_eq(beyond[1], overcast, "a share past 1 is clamped")


## The engine's ambient as through_storm hands it: the sky's [param sky] for the rest of the share.
func _mixed(lit: Array, sky: Vector3) -> Vector3:
	return sky * (1.0 - float(lit[1])) + (lit[0] as Vector3) * float(lit[1])


func test_no_storm_leaves_the_ambient_as_it_was() -> void:
	var lit: Array = DustLight.through_storm(Vector3(0.1, 0.1, 0.1), 0.4, Vector3.ONE * 2.0, 0.5, 0.0)
	assert_eq(lit[0], Vector3(0.1, 0.1, 0.1))
	assert_eq(lit[1], 0.4)


func test_a_dust_wall_overhead_lets_the_two_stream_total_reach_flat_ground() -> void:
	var beam := Vector3(2.0, 1.8, 1.5)
	var sky := Vector3(0.12, 0.13, 0.15)
	var tau := WeatherRelief.WALL_TAU  # inside a wall
	for sin_e: float in [0.34, 0.5, 0.87]:
		var light: Vector2 = DustLight.split(tau, sin_e, DustLight.STORM_ALBEDO)
		var lit: Array = DustLight.through_storm(Vector3.ZERO, 0.0, beam, sin_e, tau)
		# Flat ground: the sun's direct beam (dimmed by transmittance_at) plus the ambient.
		var ground: Vector3 = beam * sin_e * light.x + _mixed(lit, sky)
		var clear: Vector3 = beam * sin_e + sky
		assert_almost_eq(ground.x, clear.x * light.y, 1e-6, "all the light through, scaled by the two-stream total")
		assert_almost_eq(ground.z, clear.z * light.y, 1e-6)
		assert_between(ground.x / clear.x, 0.05, 0.08, "a haboob: dusk at noon, a few per cent of the clear light")
		assert_lt(beam.x * sin_e * light.x, ground.x * 0.1, "and under a tenth straight from the sun: faint shadows at most")


func test_the_storm_dust_absorbs_and_without_absorption_the_old_two_stream_comes_back() -> void:
	for tau: float in [0.0, 0.5, 2.6, 3.0, 10.0]:
		assert_almost_eq(DustLight.total(tau, 1.0), 1.0 / (1.0 + 0.75 * (1.0 - DustLight.G) * tau), 1e-9,
				"omega = 1: the conservative two-stream (tau %s)" % tau)
	assert_almost_eq(DustLight.total(3.0, 0.9999), DustLight.total(3.0, 1.0), 1e-3, "no seam next to omega = 1")
	# Eddington with omega 0.9, g 0.7 at tau 3: k = 0.333, r = 0.250, T = 0.348 (worked by hand).
	assert_almost_eq(DustLight.total(3.0, DustLight.STORM_ALBEDO), 0.348, 0.002, "a wall's storm dust: 35 %")
	assert_lt(DustLight.total(3.0, 0.8), DustLight.total(3.0, 0.9), "the darker the dust, the less through")
	var old: Array = DustLight.through_storm(Vector3.ZERO, 0.0, Vector3.ONE, 0.5, 3.0, 1.0)
	var light: Vector2 = DustLight.split(3.0, 0.5)
	assert_almost_eq(1.0 - float(old[1]), light.y, 1e-9, "omega = 1 through_storm: the sky dimmed by the old total")
	assert_lt(_mixed(DustLight.through_storm(Vector3.ZERO, 0.0, Vector3.ONE, 0.5, 3.0), Vector3.ONE).x,
			_mixed(old, Vector3.ONE).x * 0.6, "the absorbing wall gives under 60 % of what the conservative one did")


func test_the_veil_and_a_storm_mix_their_albedo_by_optical_depth() -> void:
	assert_eq(DustLight.column_albedo(0.0, 0.0), 1.0, "no dust: nothing absorbed")
	assert_eq(DustLight.column_albedo(0.0, 2.0), 1.0, "the veil's corundum alone does not absorb")
	assert_almost_eq(DustLight.column_albedo(3.0, 0.0), DustLight.STORM_ALBEDO, 1e-9, "a storm alone: its own")
	assert_almost_eq(DustLight.column_albedo(1.0, 1.0), (1.0 + DustLight.STORM_ALBEDO) * 0.5, 1e-9, "half and half")


func test_a_storm_over_the_sea_passes_its_overcast_on_dimmed() -> void:
	var overcast := Vector3(0.3, 0.3, 0.3)
	var sky := Vector3(0.05, 0.05, 0.05)
	var tau := 1.5
	var t: float = DustLight.split(tau, 1.0, DustLight.STORM_ALBEDO).y
	# Deep under the sea: no beam reaches the storm, the sea's overcast is all the light, and the storm dims it.
	var lit: Array = DustLight.through_storm(overcast, 1.0, Vector3.ZERO, 0.5, tau)
	assert_almost_eq(float(lit[1]), 1.0, 1e-9, "the sky still hidden")
	assert_almost_eq((lit[0] as Vector3).x, overcast.x * t, 1e-6, "the overcast through the storm, diffuse")
	# Half under it: the sky's half and the overcast's half are both dimmed alike.
	var half: Array = DustLight.through_storm(overcast, 0.5, Vector3.ZERO, 0.5, tau)
	assert_almost_eq(_mixed(half, sky).x, (sky.x * 0.5 + overcast.x * 0.5) * t, 1e-6)


func test_the_storm_reading_is_glided_not_stepped() -> void:
	var first := DustLight.glide_tau(0.0, 3.0, 0.016)
	assert_gt(first, 0.0)
	assert_lt(first, 0.2, "one frame takes a sliver of the step")
	assert_almost_eq(DustLight.glide_tau(0.0, 3.0, DustLight.STORM_EASE_S), 3.0 * (1.0 - exp(-1.0)), 1e-6,
			"one ease time: 63 % of the way")
	assert_almost_eq(DustLight.glide_tau(3.0, 0.0, 60.0), 0.0, 1e-6, "out of the wall the light comes back")
	assert_eq(DustLight.glide_tau(1.0, 2.0, -1.0), 1.0, "a negative frame moves nothing")


# --- The dust walls near the eye, traced through their volumes (wall_light) ---

const RADIUS_M := 6356000.0
const EYE_HEIGHT_M := 1.7


## The sun [param degrees] over the eastern horizon, as (east, north, up).
func _sun(degrees: float) -> Vector3:
	return Vector3(cos(deg_to_rad(degrees)), 0.0, sin(deg_to_rad(degrees)))


## A whole wall (risen, not thinning) whose front's middle stands [param front_east_m] east of the eye at (0, 0),
## running east ([param way_east] 1) or west (-1): its dust lies behind the front, on the side it comes from.
## The front as drawn (WeatherRelief.front_lead_m): the wall's middle is placed behind it by its lead there.
func _wall(front_east_m: float, way_east: float, depth_m: float = 1500.0, length_m: float = 30000.0,
		height_m: float = 3000.0) -> Dictionary:
	var lead: float = WeatherRelief.front_lead_m(0.0, length_m * 0.5, depth_m)
	var front: Vector2 = WeatherRelief.moved(Vector2.ZERO, Vector2(front_east_m - way_east * lead, 0.0), RADIUS_M)
	return {"id": 1, "lon": front.x, "lat": front.y, "east": way_east, "north": 0.0, "speed_m_s": 15.0,
			"length_m": length_m, "height_m": height_m, "depth_m": depth_m, "strength": 1.0, "grown": 1.0, "spent": 0.0}


## The light on level ground under [param light] (wall_light) as a share of the clear one, the sun
## [param sin_e] high and the sky giving [param sky_part] of the clear light.
func _ground_share(light: Vector4, sin_e: float, sky_part: float) -> float:
	var direct: float = exp(-light.x / maxf(sin_e, 0.02))
	return (1.0 - sky_part) * (direct + light.z) + sky_part * light.y


func test_a_wall_between_the_eye_and_the_sun_hides_it_before_its_front_arrives() -> void:
	var sun := _sun(15.0)
	var wall := _wall(1000.0, -1.0)  # coming from the sun's side, its front a kilometre away
	assert_eq(float(WeatherRelief.wall_effect(wall, Vector2.ZERO, RADIUS_M)[1]), 0.0, "no dust over the eye yet")
	var light: Vector4 = DustLight.wall_light([wall], Vector2.ZERO, EYE_HEIGHT_M, sun, RADIUS_M)
	assert_lt(exp(-light.x / sun.z), 0.3, "the sun's beam crosses the wall: mostly gone")
	assert_lt(light.y, 0.95, "a good part of the sky is behind the wall")
	assert_gt(light.y, 0.3, "the rest of the sky still lights")
	assert_gt(light.z, 0.0, "the wall's face glows with the sun's light it scattered")
	assert_between(light.w, 0.2, 0.6, "about half the dome on the wall's side is covered")


func test_a_wall_behind_the_eye_leaves_the_sun_and_dims_the_sky_a_little() -> void:
	var sun := _sun(15.0)
	var light: Vector4 = DustLight.wall_light([_wall(-1000.0, 1.0)], Vector2.ZERO, EYE_HEIGHT_M, sun, RADIUS_M)
	assert_eq(light.x, 0.0, "the sun's ray runs away from the wall")
	assert_eq(light.z, 0.0, "and none of its light goes through the dust")
	assert_lt(light.y, 1.0, "the sky behind is covered")
	assert_gt(light.y, 0.5, "only partly")
	var facing: Vector4 = DustLight.wall_light([_wall(1000.0, -1.0)], Vector2.ZERO, EYE_HEIGHT_M, sun, RADIUS_M)
	assert_almost_eq(light.y, facing.y, 0.02, "the same wall covers the same sky, whichever side the sun is")


## The light as a wall [param height_m] tall comes from the sun's side, the sun [param degrees] high: one line by
## distance of its front (negative: inside), the old reading (the column over the eye) beside it. Checks that
## the beam only dims until the front.
func _approach(height_m: float, degrees: float) -> PackedStringArray:
	var sin_e: float = _sun(degrees).z
	var previous := 1.0
	var table := PackedStringArray()
	for front_m: float in [14000.0, 11000.0, 9000.0, 7000.0, 5000.0, 3000.0, 2000.0, 1000.0, 500.0, 200.0, 0.0,
			-100.0, -300.0, -750.0, -1500.0, -2000.0, -3000.0, -4000.0, -5000.0, -6000.0, -7000.0, -8000.0, -10000.0]:
		var wall := _wall(front_m, -1.0, 1500.0, 30000.0, height_m)
		var light: Vector4 = DustLight.wall_light([wall], Vector2.ZERO, EYE_HEIGHT_M, _sun(degrees), RADIUS_M)
		var beam: float = exp(-light.x / sin_e)
		var column: float = float(WeatherRelief.wall_effect(wall, Vector2.ZERO, RADIUS_M)[1])
		var old_total: float = DustLight.total(column, DustLight.STORM_ALBEDO)
		var old := Vector4(column * sin_e, old_total, maxf(old_total - exp(-column / sin_e), 0.0), 0.0)
		table.append("front %6.0f m: beam %.3f, sky through %.3f, covered %.2f, sun diffuse %.3f, ground %.3f "
				% [front_m, beam, light.y, light.w, light.z, _ground_share(light, sin_e, 0.3)]
				+ "(column over the eye %.2f, was ground %.3f)" % [column, _ground_share(old, sin_e, 0.3)])
		if front_m >= 0.0:
			# Within a hundredth of the clear beam: at the front's foot the dust is still rising (WALL_DUST_RAMP_M),
			# a low sun's ray grazes that thinner air (0.5 % of the beam at 500 m, 0.7 % at 200 m).
			assert_lte(beam, previous + 0.01, "the beam only dims as the front comes (%s m)" % front_m)
			previous = beam
	return table


func test_the_sun_fades_as_the_front_comes_not_at_once() -> void:
	var sin_e: float = _sun(15.0).z
	gut.p("Sun 15 deg behind a 3 km wall, 1.5 km deep, the sky giving 30 % of the clear light:\n"
			+ "\n".join(_approach(3000.0, 15.0)))
	gut.p("Sun 15 deg behind a 1 km wall:\n" + "\n".join(_approach(1000.0, 15.0)))
	gut.p("Sun 30 deg behind a 3 km wall:\n" + "\n".join(_approach(3000.0, 30.0)))
	var far: Vector4 = DustLight.wall_light([_wall(20000.0, -1.0)], Vector2.ZERO, EYE_HEIGHT_M, _sun(15.0), RADIUS_M)
	assert_almost_eq(exp(-far.x / sin_e), 1.0, 1e-9, "20 km away the sun's ray passes over the wall")
	var near: Vector4 = DustLight.wall_light([_wall(5000.0, -1.0)], Vector2.ZERO, EYE_HEIGHT_M, _sun(15.0), RADIUS_M)
	assert_lt(exp(-near.x / sin_e), 0.5, "5 km away the wall already hides the sun")


func test_nothing_jumps_at_the_front() -> void:
	var ahead: Vector4 = DustLight.wall_light([_wall(1.0, -1.0)], Vector2.ZERO, EYE_HEIGHT_M, _sun(15.0), RADIUS_M)
	var inside: Vector4 = DustLight.wall_light([_wall(-1.0, -1.0)], Vector2.ZERO, EYE_HEIGHT_M, _sun(15.0), RADIUS_M)
	for k in 4:
		assert_almost_eq(inside[k], ahead[k], 0.01, "a metre either side of the front (component %d)" % k)


func test_deep_in_a_wide_wall_the_light_is_the_column_over_the_eye() -> void:
	# A wall so deep and long that every line toward the sky leaves it by its top: the column's light.
	var wall := _wall(-200000.0, -1.0, 400000.0, 4000000.0)
	var tau: float = float(WeatherRelief.wall_effect(wall, Vector2.ZERO, RADIUS_M)[1])
	assert_almost_eq(tau, WeatherRelief.WALL_TAU * WeatherRelief.wall_share(1.0, 2000000.0, 400000.0, 200000.0, 0.0), 1e-3,
			"the tail's dust overhead")
	assert_gt(tau, 1.0, "still dense there")
	var sun := Vector3(0.6, 0.0, 0.8)
	var light: Vector4 = DustLight.wall_light([wall], Vector2.ZERO, EYE_HEIGHT_M, sun, RADIUS_M)
	var column: Vector2 = DustLight.split(tau, sun.z, DustLight.STORM_ALBEDO)
	assert_almost_eq(light.x, tau, tau * 0.02, "the beam: the column's Beer")
	# The low lines toward the sky cross the front's wander, which grows with the depth (WeatherRelief.front_lead_m:
	# hundreds of kilometres in this device): the column they read varies around the one over the eye.
	assert_almost_eq(light.y, column.y, 0.05, "the sky: the column's two-stream total")
	assert_almost_eq(light.z, column.y - column.x, 0.02, "the sun's diffuse share: the column's")
	assert_almost_eq(light.w, 1.0, 0.02, "the whole sky covered")
	# And the engine's ambient comes out as through_storm gave it from the column.
	var beam := Vector3(2.0, 1.8, 1.5)
	var sky := Vector3(0.12, 0.13, 0.15)
	var traced: Array = DustLight.dimmed_ambient(Vector3.ZERO, 0.0, beam * (sun.z * light.z), light.y)
	var old: Array = DustLight.through_storm(Vector3.ZERO, 0.0, beam, sun.z, tau)
	assert_almost_eq(_mixed(traced, sky).x, _mixed(old, sky).x, _mixed(old, sky).x * 0.05, "the same light in the wall")


func test_dusk_holds_past_the_front_and_the_light_comes_back_with_the_tail() -> void:
	var sin_e: float = _sun(15.0).z
	var at_front: float = _ground_share(DustLight.wall_light([_wall(0.0, -1.0)], Vector2.ZERO, EYE_HEIGHT_M, _sun(15.0),
			RADIUS_M), sin_e, 0.3)
	assert_lt(at_front, 0.3, "at the front: dusk already")
	var previous := 0.0
	for past_m: float in [100.0, 300.0, 1000.0, 2000.0, 4000.0, 6000.0, 8000.0]:
		var ground: float = _ground_share(DustLight.wall_light([_wall(-past_m, -1.0)], Vector2.ZERO, EYE_HEIGHT_M,
				_sun(15.0), RADIUS_M), sin_e, 0.3)
		if past_m <= 300.0:
			assert_lt(ground, at_front + 0.05, "no brightening right behind the front (%s m)" % past_m)
		if past_m <= 1000.0:
			assert_lt(ground, 0.4, "dusk holds over the first kilometre of the tail (%s m)" % past_m)
		assert_gte(ground, previous - 0.02, "the light only comes back along the tail (%s m)" % past_m)
		previous = ground
	assert_gt(previous, 0.9, "past the tail's end: the clear light, but for the tail in the sky behind")


func test_the_tail_ends_without_a_step() -> void:
	var depth := 1500.0
	var reach: float = WeatherRelief.wall_reach_m(depth)
	assert_almost_eq(WeatherRelief.wall_share(1.0, 10000.0, depth, reach - 1.0, 0.0), 0.0, 1e-4, "nothing left at its end")
	assert_eq(WeatherRelief.wall_share(1.0, 10000.0, depth, reach + 1.0, 0.0), 0.0)
	var front: float = WeatherRelief.wall_share(1.0, 10000.0, depth, WeatherRelief.WALL_DUST_RAMP_M, 0.0)
	# Its dust rises over WALL_DUST_RAMP_M as the drawn wall's edge softens, the tail already thinning by then.
	assert_between(front, 0.75, 1.0, "right behind the front: most of the whole wall's dust")
	assert_almost_eq(WeatherRelief.wall_share(1.0, 10000.0, depth, depth * WeatherRelief.WALL_TAIL_FALL, 0.0), exp(-1.0),
			0.01, "thinned by e every WALL_TAIL_FALL depths")
	assert_almost_eq(WeatherRelief.WALL_TAIL_DEPTHS, WeatherPhenomena.WALL_DEEPER - WeatherPhenomena.WALL_FRONT_MARGIN, 1e-9,
			"the tail ends where the drawn box does")
	var wall := _wall(0.0, -1.0)
	assert_almost_eq(WeatherRelief.wall_tall_at(wall, 0.0), WeatherRelief.wall_tall(wall), 1e-6, "at the front: its height")
	assert_almost_eq(WeatherRelief.wall_tall_at(wall, reach), WeatherRelief.wall_tall(wall) * WeatherRelief.WALL_TAIL_CREST,
			WeatherRelief.wall_tall(wall) * 0.01, "its tail's end lies low")


func test_no_wall_or_over_its_top_leaves_the_light() -> void:
	assert_eq(DustLight.wall_light([], Vector2.ZERO, EYE_HEIGHT_M, _sun(15.0), RADIUS_M), DustLight.NO_WALLS)
	assert_eq(DustLight.wall_light([_wall(1000.0, -1.0)], Vector2.ZERO, 3500.0, _sun(15.0), RADIUS_M), DustLight.NO_WALLS,
			"over the wall's top every line toward the sky leaves it behind")
	var lit: Array = DustLight.dimmed_ambient(Vector3(0.1, 0.2, 0.3), 0.4, Vector3.ZERO, 1.0)
	assert_eq(lit[0], Vector3(0.1, 0.2, 0.3), "nothing taken, nothing given: the ambient as it was")
	assert_eq(lit[1], 0.4)


func test_the_walls_dust_comes_out_of_the_sample_column() -> void:
	var sample := {"dust_tau": 5.0, "wall_dust_tau": 4.0, "wall_top_m": 1000.0}
	assert_eq(WeatherRelief.walls_dust_in(sample, 500.0), 4.0, "under the wall's top: all of it")
	assert_eq(WeatherRelief.walls_dust_in(sample, 1000.0 + WeatherRelief.WALL_TOP_FADE_M), 0.0, "over it: none left")
	assert_eq(WeatherRelief.walls_dust_in({"dust_tau": 2.0}, 0.0), 0.0, "no wall: none")


func test_tracing_three_walls_is_cheap() -> void:
	var walls := [_wall(1000.0, -1.0), _wall(-3000.0, 1.0), _wall(6000.0, -1.0, 3000.0, 50000.0)]
	var runs := 50
	var started := Time.get_ticks_usec()
	for k in runs:
		DustLight.wall_light(walls, Vector2.ZERO, EYE_HEIGHT_M, _sun(15.0), RADIUS_M)
	var each_us: float = float(Time.get_ticks_usec() - started) / runs
	gut.p("wall_light, 3 walls: %.0f us a reading, %.3f ms a frame at 60 fps read every %.2f s"
			% [each_us, each_us / 1000.0 / (60.0 * WeatherSky.WALL_REFRESH_S), WeatherSky.WALL_REFRESH_S])
	assert_lt(each_us, 20000.0, "a reading stays within a frame's budget even in a debug build")
