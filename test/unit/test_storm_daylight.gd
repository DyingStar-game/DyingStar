extends GutTest
## A storm's dust on the daylight (Planet.storm_transmittance): the direct beam through a vertical
## optical depth τ of dust, exp(-τ / sin e), slanted by the star's height — nothing in clear air, a
## tenth left under τ 2.3 overhead, far less when the star is low. What the Photocell reads, so the
## village lamps come on in a storm.


func test_clear_air_lets_everything_through() -> void:
	assert_eq(Planet.storm_transmittance(0.0, 60.0), 1.0)
	assert_eq(Planet.storm_transmittance(-1.0, 60.0), 1.0, "no negative dust")


func test_the_beam_follows_beer_s_law_along_its_slant() -> void:
	assert_almost_eq(Planet.storm_transmittance(1.0, 90.0), exp(-1.0), 1e-9, "overhead: e^-τ")
	assert_almost_eq(Planet.storm_transmittance(1.0, 30.0), exp(-2.0), 1e-9, "at 30°: twice the dust on the way")
	assert_almost_eq(Planet.storm_transmittance(2.3, 90.0), 0.1, 0.001, "τ 2.3: a tenth of the light")
	assert_lt(Planet.storm_transmittance(1.0, 1.0), 1e-6, "a star on the horizon under a storm: night")
	assert_gt(Planet.storm_transmittance(0.1, 0.5), 0.0, "the slant is floored: never a division by zero")
