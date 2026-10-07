extends GutTest
## ShelterProbe.combine, the rule that turns six rays into what the weather keeps on a body: out in the
## open nothing is taken; walled in everything is; a wall upwind gives its lee, nearer is more; in a
## trench the lee is the canyon's business and is left out.


func test_the_open_keeps_everything() -> void:
	var s : Dictionary = ShelterProbe.open()
	assert_eq(s["enclosed"], 0.0)
	assert_eq(s["lee"], 0.0)
	assert_eq(s["shelter"], 0.0)
	assert_eq(s["wind_factor"], 1.0)


func test_walled_in_stops_everything() -> void:
	var s : Dictionary = ShelterProbe.enclosed()
	assert_eq(s["enclosed"], 1.0)
	assert_eq(s["shelter"], 1.0)
	assert_eq(s["wind_factor"], 0.0)


func test_a_roof_and_two_walls_shelter_in_part() -> void:
	var s : Dictionary = ShelterProbe.combine(true, 2, -1.0)
	assert_almost_eq(float(s["enclosed"]), 0.6, 1e-9, "three of five rays")
	assert_almost_eq(float(s["shelter"]), 0.6, 1e-9)
	assert_almost_eq(float(s["wind_factor"]), 0.4, 1e-9, "what the wind keeps")
	assert_almost_eq(float(ShelterProbe.combine(true, 0, -1.0)["wind_factor"]), 0.8, 1e-9, "a roof alone: a fifth")


func test_a_wall_upwind_gives_its_lee_nearer_is_more() -> void:
	var touching : Dictionary = ShelterProbe.combine(false, 0, 0.0)
	assert_almost_eq(float(touching["lee"]), 1.0, 1e-9)
	assert_almost_eq(float(touching["wind_factor"]), 1.0 - ShelterProbe.LEE_WIND_CUT, 1e-9, "a full lee leaks a fifth")
	assert_almost_eq(float(touching["shelter"]), 0.5, 1e-9, "half a shelter for the ears and the eyes")
	var half : Dictionary = ShelterProbe.combine(false, 0, ShelterProbe.LEE_M * 0.5)
	assert_almost_eq(float(half["lee"]), 0.5, 1e-9, "halfway to the reach: half the lee")
	var far : Dictionary = ShelterProbe.combine(false, 0, ShelterProbe.LEE_M + 1.0)
	assert_eq(far["lee"], 0.0, "beyond the reach: no lee")
	var ignored : Dictionary = ShelterProbe.combine(false, 0, 0.0, false)
	assert_eq(ignored["lee"], 0.0, "in a trench the lee is the canyon's, counted once")
	assert_eq(ignored["wind_factor"], 1.0)


func test_more_walls_than_four_are_four() -> void:
	assert_eq(ShelterProbe.combine(true, 9, -1.0)["enclosed"], 1.0)
