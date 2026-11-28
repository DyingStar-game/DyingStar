extends GutTest

## The locate probe's frame helpers (LocateProbe): a direction in a body's own frame, turned onto the chart's
## drawn sphere and onto the world, its lon / lat in degrees, and the angle that says "the other side".
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_locate_probe.gd


func test_a_direction_is_given_in_every_frame() -> void:
	# The chart's own spin: tilted about BACK, turned about UP (StarMap._spin_basis, Planet.spin_basis_at).
	var drawn := Basis(Vector3.BACK, deg_to_rad(15.0)) * Basis(Vector3.UP, deg_to_rad(90.0))
	var facts := LocateProbe.direction_facts(Vector3(2.0, 0.0, 0.0), drawn, Basis.IDENTITY)
	assert_eq(facts["local"], Vector3.RIGHT, "normalised")
	assert_almost_eq((facts["drawn"] as Vector3).distance_to(drawn * Vector3.RIGHT), 0.0, 1e-6)
	assert_almost_eq((facts["world"] as Vector3).distance_to(Vector3.RIGHT), 0.0, 1e-6)
	assert_eq(facts["local_lonlat_deg"], Vector2(0.0, 0.0), "+X is lon 0, lat 0 (HEALPix, Y up)")


func test_the_drawn_frame_is_undone_by_the_charts_own_inverse() -> void:
	# What the chart frames is sphere.basis * local (_frame_on_surface); what it reads back from a drawn
	# direction is body_local_offset. Round trip: the same place, not its antipode.
	var drawn := Basis(Vector3.BACK, deg_to_rad(23.5)) * Basis(Vector3.UP, deg_to_rad(200.0))
	var local := Vector3(0.3, 0.8, -0.52).normalized()
	var facts := LocateProbe.direction_facts(local, drawn, null)
	var back: Vector3 = StarMap.body_local_offset(drawn, facts["drawn"])
	assert_almost_eq(LocateProbe.arc_deg(back, local), 0.0, 1e-3)
	assert_false(facts.has("world"), "no live planet: no world direction")


func test_lon_lat_are_degrees() -> void:
	var north := LocateProbe.direction_facts(Vector3.UP, Basis.IDENTITY, null)
	assert_almost_eq((north["local_lonlat_deg"] as Vector2).y, 90.0, 1e-4, "the pole is lat 90")
	var east := LocateProbe.direction_facts(Vector3(0.0, 0.0, -1.0), Basis.IDENTITY, null)
	assert_almost_eq((east["local_lonlat_deg"] as Vector2).x, 90.0, 1e-4, "-Z is lon 90")


func test_the_other_side_is_a_hundred_and_eighty_degrees() -> void:
	assert_almost_eq(LocateProbe.arc_deg(Vector3.RIGHT, Vector3.LEFT), 180.0, 1e-4)
	assert_almost_eq(LocateProbe.arc_deg(Vector3.RIGHT, Vector3(5.0, 0.0, 0.0)), 0.0, 1e-4)
	assert_eq(LocateProbe.arc_deg(Vector3.ZERO, Vector3.UP), -1.0, "no direction, no angle")
	assert_eq(LocateProbe.direction_facts(Vector3.ZERO, Basis.IDENTITY, null), {}, "no direction, no facts")


func test_a_basis_is_written_as_axes_and_degrees() -> void:
	var facts := LocateProbe.basis_facts(Basis(Vector3.UP, deg_to_rad(90.0)).scaled(Vector3.ONE * 3.0))
	assert_almost_eq((facts["x"] as Vector3).length(), 1.0, 1e-5, "orthonormalised: the chart's scale is not a turn")
	assert_almost_eq((facts["euler_deg"] as Vector3).y, 90.0, 1e-3)


func test_the_raw_data_keep_what_names_a_place() -> void:
	var request := {"mission": {"zones": [{"kind": "poi", "poiId": "z"}], "kind": "dynamic"},
		"objectives": [{"id": "o1", "type": "transport", "locationFrom": {"village": "M0001"},
			"locationTo": {"village": "F0002"}, "params": {"via": "warehouse"}, "secret": "left out"}, "nope"]}
	var raw := LocateProbe.raw_of(request)
	assert_eq(raw["zones"], [{"kind": "poi", "poiId": "z"}])
	assert_eq((raw["objectives"] as Array).size(), 1, "only objectives")
	assert_eq(raw["objectives"][0]["locationFrom"], {"village": "M0001"})
	assert_false((raw["objectives"][0] as Dictionary).has("secret"))
	assert_eq(LocateProbe.raw_of({}), {"zones": null, "kind": null, "objectives": []})
