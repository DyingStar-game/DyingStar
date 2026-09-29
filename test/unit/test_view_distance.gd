extends GutTest
## The Graphics distance options. Terrain distance on PlanetTerrain's LOD: the ground near the camera
## keeps full detail and the scaling is continuous. DrawRange: a decoration's range is rescaled from
## its original band rather than compounded. StructureDrawRange: buildings are tracked, the station
## and whatever can move are not.

const NEAR : float = PlanetTerrain.VIEW_DISTANCE_NEAR_M


func test_the_ground_near_the_camera_is_never_scaled() -> void:
	for mult in [0.5, 1.0, 2.0]:
		assert_almost_eq(PlanetTerrain._view_scaled(NEAR * 0.5, mult), NEAR * 0.5, 0.001, "x%s near" % mult)
		assert_almost_eq(PlanetTerrain._view_scaled(NEAR, mult), NEAR, 0.001, "x%s at the edge" % mult)


func test_beyond_it_the_option_stretches_or_compresses() -> void:
	var far : float = NEAR + 1000.0
	assert_almost_eq(PlanetTerrain._view_scaled(far, 1.0), far, 0.001, "x1 changes nothing")
	assert_almost_eq(PlanetTerrain._view_scaled(far, 2.0), NEAR + 500.0, 0.001, "x2: seen as closer, finer")
	assert_almost_eq(PlanetTerrain._view_scaled(far, 0.5), NEAR + 2000.0, 0.001, "x0.5: seen as further, coarser")


func test_a_draw_range_rescales_from_its_band() -> void:
	var grass := MultiMeshInstance3D.new()
	autofree(grass)
	DrawRange.track(grass, "foliage_distance", 10.0, 400.0)
	assert_true(grass.is_in_group(DrawRange.group("foliage_distance")), "listed under its option")
	DrawRange.rescale(grass, 1.5)
	assert_almost_eq(grass.visibility_range_end, 600.0, 0.001, "scaled")
	DrawRange.rescale(grass, 0.5)
	assert_almost_eq(grass.visibility_range_begin, 5.0, 0.001, "begin rescaled from the band")
	assert_almost_eq(grass.visibility_range_end, 200.0, 0.001, "end rescaled from the band, not from 600")


func test_a_missing_decoration_is_ignored() -> void:
	DrawRange.rescale(null, 2.0)
	assert_true(true, "no error on a chunk without that decoration")


func test_a_building_is_tracked_mesh_by_mesh_even_later_ones() -> void:
	var building := NetStaticBody.new()
	var wall := MeshInstance3D.new()
	building.add_child(wall)
	StructureDrawRange.attach_to(building)
	add_child_autofree(building)
	assert_true(DrawRange.is_tracked(wall), "its mesh has a draw distance")
	assert_gt(wall.visibility_range_end, 0.0, "and it is applied")
	var apartment := MeshInstance3D.new()
	building.add_child(apartment)
	assert_true(DrawRange.is_tracked(apartment), "a mesh built after the spawn is covered too")


func test_the_station_and_what_moves_are_left_alone() -> void:
	var station := OrbitalStation.new()
	var hull := MeshInstance3D.new()
	station.add_child(hull)
	StructureDrawRange.attach_to(station)
	assert_false(DrawRange.is_tracked(hull), "the station stays visible from the ground")
	station.free()
	var depot := NetStaticBody.new()
	var crate := RigidBody3D.new()
	var crate_mesh := MeshInstance3D.new()
	crate.add_child(crate_mesh)
	depot.add_child(crate)
	StructureDrawRange.attach_to(depot)
	assert_false(DrawRange.is_tracked(crate_mesh), "a loose prop inside a building keeps its own rules")
	depot.free()


func test_an_authored_range_is_kept() -> void:
	var building := NetStaticBody.new()
	var sign := MeshInstance3D.new()
	sign.visibility_range_end = 40.0
	building.add_child(sign)
	StructureDrawRange.attach_to(building)
	assert_almost_eq(sign.visibility_range_end, 40.0, 0.001, "a range set on purpose is not overridden")
	building.free()


func test_a_planet_brings_its_own_buildings() -> void:
	var planet := Node3D.new()
	var depot := NetStaticBody.new()
	var roof := MeshInstance3D.new()
	depot.add_child(roof)
	planet.add_child(depot)
	var rock := MeshInstance3D.new()
	planet.add_child(rock)
	StructureDrawRange.attach_to(planet)
	assert_true(DrawRange.is_tracked(roof), "a depot placed in the planet scene is found")
	assert_false(DrawRange.is_tracked(rock), "the rest of the planet is not a building")
	planet.free()
