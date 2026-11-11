extends GutTest

## The zones an inspection sends a player to, as the star chart marks them (MissionSites): read from the
## mission's `visit` objectives, and laid flat on the planet's ground.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_mission_sites.gd


func _visit(place: Variant, status: String = "pending") -> Dictionary:
	return {"type": "visit", "status": status, "locationTo": place}


func test_a_visit_objective_gives_its_zone() -> void:
	var place := {"name": "F0001-B", "scene": "tarsis_3", "radiusM": 1500, "position": {"x": 10.0, "y": 20.0, "z": 30.0}}
	var sites := MissionSites.sites_of([_visit(place)])
	assert_eq(sites.size(), 1)
	assert_eq(sites[0]["name"], "F0001-B")
	assert_eq(sites[0]["scene"], "tarsis_3")
	assert_eq(sites[0]["position"], Vector3(10.0, 20.0, 30.0))
	assert_eq(sites[0]["radius"], 1500.0)
	assert_eq(sites[0]["poi"], "", "no point of interest said")


func test_a_zone_keeps_the_id_of_its_point_of_interest() -> void:
	# "Show on the chart" names the point: the zone is found by it.
	var place := {"name": "A", "poiUuid": "d88453a2", "position": {"x": 1.0, "y": 2.0, "z": 3.0}}
	assert_eq(MissionSites.sites_of([_visit(place)])[0]["poi"], "d88453a2")
	place["poiUuid"] = null
	assert_eq(MissionSites.sites_of([_visit(place)])[0]["poi"], "")


func test_a_zone_without_a_radius_takes_the_default() -> void:
	var sites := MissionSites.sites_of([_visit({"name": "A", "position": {"x": 1, "y": 2, "z": 3}})])
	assert_eq(sites[0]["radius"], MissionSites.DEFAULT_RADIUS_M)


func test_only_visits_still_to_do_with_a_position_are_zones() -> void:
	var place := {"name": "A", "position": {"x": 1.0, "y": 2.0, "z": 3.0}}
	assert_eq(MissionSites.sites_of([{"type": "transport", "locationTo": place}]).size(), 0, "not a visit")
	assert_eq(MissionSites.sites_of([_visit(place, "completed")]).size(), 0, "already there")
	assert_eq(MissionSites.sites_of([_visit({"name": "A", "position": null})]).size(), 0, "nowhere")
	assert_eq(MissionSites.sites_of([_visit(null)]).size(), 0)
	assert_eq(MissionSites.sites_of(null).size(), 0)


func test_a_zone_lies_flat_on_the_ground() -> void:
	for position: Vector3 in [Vector3(3.0e6, 4.0e6, 3.9e6), Vector3(0.0, 6.0e6, 0.0), Vector3(-5.0e6, -1.0, 2.0)]:
		var frame := MissionSites.ground_frame(position)
		assert_eq(frame.origin, position)
		assert_almost_eq(frame.basis.y.dot(position.normalized()), 1.0, 1.0e-6, "its Y is the planet's up")
		assert_almost_eq(frame.basis.determinant(), 1.0, 1.0e-6, "a plain rotation")
	assert_eq(MissionSites.ground_frame(Vector3.ZERO), Transform3D.IDENTITY)
