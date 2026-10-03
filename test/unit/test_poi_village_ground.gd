extends GutTest
## A POI village stands itself on the ground before spawning its items: their poses are composed with
## the village's, and startup_items.json stored 54 villages of tarsis_3 at the same 8 363 m — the
## buildings came back down on their TerrainPad, the mining depot stayed kilometres up.

const RADIUS := 6356000.0
const VillageScript := preload("res://scenes/_universe/structures/urban/poi_villages.gd")


## An inert Planet with a flat PlanetData (no height pack: the relief reads 0 m everywhere).
func _planet() -> Planet:
	var planet := Planet.new()
	var terrain := PlanetTerrain.new()
	terrain.name = "PlanetTerrain"
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	terrain.planet_data = data
	planet.planet_terrain = terrain
	planet.add_child(terrain)
	add_child_autofree(planet)
	return planet


func _village(planet: Planet, altitude: float, tilt_deg: float) -> Node3D:
	var village := Node3D.new()
	village.set_script(VillageScript)
	village.position = Vector3(RADIUS + altitude, 0.0, 0.0)
	# Square on +X is "+Y along +X" (-90° about Z); tilt it from there, and give it a heading.
	village.basis = Basis(Vector3(0, 0, 1), deg_to_rad(-(90.0 + tilt_deg))) * Basis(Vector3.UP, 0.6)
	planet.add_child(village)
	return village


func test_a_village_stored_too_high_stands_on_the_ground() -> void:
	var village := _village(_planet(), 2723.0, 4.0)
	assert_true(village._stand_on_ground())
	assert_almost_eq(village.position.length() - RADIUS, 0.0, 0.01, "on the ground under its centre")
	assert_almost_eq(rad_to_deg(village.basis.y.angle_to(village.position.normalized())), 0.0, 0.01,
			"standing square: its items are composed with this frame")


func test_a_village_stored_underground_comes_up() -> void:
	var village := _village(_planet(), -800.0, 0.0)
	assert_true(village._stand_on_ground())
	assert_almost_eq(village.position.length() - RADIUS, 0.0, 0.01)


func test_the_heading_is_kept() -> void:
	var village := _village(_planet(), 2723.0, 4.0)
	var up_before: Vector3 = village.position.normalized()
	var fwd_before: Vector3 = village.basis.z - up_before * village.basis.z.dot(up_before)
	village._stand_on_ground()
	var up: Vector3 = village.position.normalized()
	var fwd: Vector3 = village.basis.z - up * village.basis.z.dot(up)
	assert_almost_eq(rad_to_deg(fwd.angle_to(fwd_before)), 0.0, 0.01, "same direction on the ground")


func test_no_elevation_ever_leaves_the_village_where_it_is() -> void:
	# A pack that has no tile there and no streaming source to bring one: reading the relief would
	# give the flat global fallback, kilometres off. Better the stored pose.
	var planet := _planet()
	planet.planet_terrain.planet_data.chunk_heightmaps_dir = "res://does_not_exist_chunks"
	var village := _village(planet, 2723.0, 0.0)
	assert_true(village._stand_on_ground(), "the items still spawn")
	assert_almost_eq(village.position.length() - RADIUS, 2723.0, 0.01, "at the stored pose")
