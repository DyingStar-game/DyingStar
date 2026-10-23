extends GutTest
## LightProbe, the development probe that names the lamps lighting the aimed point: which lamps reach
## a point (their range, a spot's cone) and what is said of each (lit, or a leak through a wall, with a
## shadow or without). The rays themselves need a physics frame and are seen in the game.


func test_a_lamp_reaches_what_is_within_its_range() -> void:
	var at := Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0))
	assert_true(LightProbe.reaches(at, "omni", 3.0, 180.0, Vector3(0.0, 0.0, 1.0)), "2.2 m: within 3 m")
	assert_false(LightProbe.reaches(at, "omni", 2.0, 180.0, Vector3(0.0, 0.0, 1.0)), "2.2 m: past 2 m")
	assert_true(LightProbe.reaches(at, "area", 5.0, 180.0, Vector3(4.0, 0.0, 0.0)), "an area light: all around")
	assert_false(LightProbe.reaches(at, "", 50.0, 180.0, Vector3.ZERO), "not a lamp with a reach")


func test_a_spot_reaches_only_inside_its_cone() -> void:
	var down := Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 2.0, 0.0))  # -Z turned to -Y
	assert_true(LightProbe.reaches(down, "spot", 5.0, 30.0, Vector3(0.5, 0.0, 0.0)), "below it, 14° off its axis")
	assert_false(LightProbe.reaches(down, "spot", 5.0, 30.0, Vector3(3.0, 1.5, 0.0)), "beside it, out of the cone")


func test_the_verdict_names_the_wall_and_the_shadow() -> void:
	assert_eq(LightProbe.verdict("", false), "lights it, nothing in between")
	assert_string_contains(LightProbe.verdict("0-1-0", false), "casts no shadow", "the budget or the scene")
	assert_string_contains(LightProbe.verdict("0-1-0", true), "does not stop it", "a shadow that lets it through")
	assert_string_contains(LightProbe.verdict("0-1-0", true), "0-1-0", "the wall is named")


func test_a_star_is_open_hidden_or_leaking() -> void:
	assert_string_contains(LightProbe.star_verdict("", true), "open toward it", "through the door")
	assert_string_contains(LightProbe.star_verdict("0-1-0", true), "keeps it out", "under the roof, shadowed")
	assert_string_contains(LightProbe.star_verdict("0-1-0", false), "LEAK", "under the roof, no shadow")


func test_its_kind_and_reach_come_from_the_lamp() -> void:
	var omni := OmniLight3D.new()
	omni.omni_range = 1.8
	var spot := SpotLight3D.new()
	spot.spot_range = 30.0
	assert_eq(LightProbe.kind_of(omni), "omni")
	assert_almost_eq(LightProbe.reach_of(omni), 1.8, 1e-6)
	assert_eq(LightProbe.kind_of(spot), "spot")
	assert_almost_eq(LightProbe.reach_of(spot), 30.0, 1e-6)
	omni.free()
	spot.free()
