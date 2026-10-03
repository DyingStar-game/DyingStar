extends GutTest
## The POI zones are the networked POI villages: they keep the crack network out of their ground and
## the mining zones away. They arrive at run time (the server from its registry, a client from the
## network), so they are dynamic — unlike the POI nodes the planet scenes used to bake.

const RADIUS := 6356000.0


func _terrain() -> PlanetTerrain:
	var planet := Planet.new()
	var terrain := PlanetTerrain.new()
	terrain.name = "PlanetTerrain"
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 13
	data.crack_poi_margin_m = 300.0
	terrain.planet_data = data
	planet.planet_terrain = terrain
	planet.add_child(terrain)
	add_child_autofree(planet)
	return terrain


func _at(lon: float, lat: float, altitude: float = 0.0) -> Vector3:
	return HEALPix.lonlat2vec(lon, lat) * (RADIUS + altitude)


func test_a_village_keeps_the_canyons_out_and_gives_them_back_when_deleted() -> void:
	var t := _terrain()
	var dir := _at(-39.555, 24.857).normalized()
	assert_eq(t.planet_data.crack_clearance(dir), 1.0, "no village yet: full canyon depth")
	t.set_poi_zone("v1", "mining_village_01", _at(-39.555, 24.857, 5632.0), 1000.0)
	assert_eq(t.planet_data.crack_clearance(dir), 0.0, "inside the village: whole ground")
	t.remove_poi_zone("v1")
	assert_eq(t.planet_data.crack_clearance(dir), 1.0, "village deleted: the canyon comes back")


func test_the_zone_follows_the_village_s_direction_not_its_stored_altitude() -> void:
	# startup_items.json stored 54 villages at the same 8 363 m: the zone is a direction and a radius.
	var t := _terrain()
	t.set_poi_zone("v3", "mining_village_03", _at(-39.6995, 24.7619, 8363.0), 1000.0)
	assert_eq(t.planet_data.crack_clearance(_at(-39.6995, 24.7619).normalized()), 0.0)


func test_mining_sees_the_zone_on_the_ground() -> void:
	# A mining zone is sited at the ground: a village sphere left 2.7 km up would never block it.
	var t := _terrain()
	t.set_poi_zone("v3", "mining_village_03", _at(-39.6995, 24.7619, 2723.0), 1000.0)
	var spheres := t.poi_spheres()
	assert_eq(spheres.size(), 1)
	assert_eq(spheres[0]["name"], "mining_village_03")
	var ground := _at(-39.6995, 24.7619)  # no height pack: the ground is the radius
	assert_almost_eq((spheres[0]["position"] as Vector3).distance_to(ground), 0.0, 0.01)
	assert_false(PlanetTerrain.first_blocking_poi(ground, spheres, 10.0).is_empty())


func test_a_chunk_near_a_village_stays_out_of_the_disk_cache() -> void:
	# The cache key is planet-wide and the villages are not baked data.
	var t := _terrain()
	var nside := 1 << t.planet_data.max_quadtree_depth
	var near_ip := HEALPix.vec2pix_nest(nside, _at(-39.555, 24.857).normalized())
	var far_ip := HEALPix.vec2pix_nest(nside, _at(40.0, -10.0).normalized())
	assert_false(t.planet_data.chunk_cache_ineligible(nside, near_ip), "no village yet")
	t.set_poi_zone("v1", "mining_village_01", _at(-39.555, 24.857), 1000.0)
	assert_true(t.planet_data.chunk_cache_ineligible(nside, near_ip))
	assert_false(t.planet_data.chunk_cache_ineligible(nside, far_ip), "far away: cached as before")


func test_a_village_re_seated_on_its_ground_changes_nothing() -> void:
	# The server stands the village on the ground (a radial move): same zone, nothing to re-carve.
	var t := _terrain()
	t.set_poi_zone("v1", "mining_village_01", _at(-39.555, 24.857, 8363.0), 1000.0)
	var before: Array = t.planet_data._crack_pois
	t.set_poi_zone("v1", "mining_village_01", _at(-39.555, 24.857, 5632.0), 1000.0)
	assert_same(t.planet_data._crack_pois, before, "the published list is not even replaced")


func test_the_json_pois_and_the_networked_ones_add_up() -> void:
	# The JSON's POIs are baked (in the cache key, from the first chunk); the networked villages are
	# added on top at run time and change no key.
	var t := _terrain()
	var town := _at(10.0, 5.0).normalized()
	t.planet_data.set_crack_exclusions([{"dir": town, "radius": 2000.0}])
	var fp := t.planet_data.crack_exclusion_fingerprint()
	assert_ne(fp, "")
	t.set_poi_zone("v1", "mining_village_01", _at(-39.555, 24.857), 1000.0)
	assert_eq(t.planet_data.crack_clearance(town), 0.0, "the JSON's town")
	assert_eq(t.planet_data.crack_clearance(_at(-39.555, 24.857).normalized()), 0.0, "the village")
	assert_eq(t.planet_data.crack_exclusion_fingerprint(), fp, "a networked village re-keys nothing")
	t.remove_poi_zone("v1")
	assert_eq(t.planet_data.crack_clearance(town), 0.0, "the JSON's town stays")


func test_the_json_of_a_body_gives_its_exclusions() -> void:
	# tarsis_3's POI file is the level design's list: every POI with a radius keeps the canyons out.
	var excl := PlanetTerrain.poi_crack_exclusions("tarsis_3")
	var with_radius := StarMapPoi.load_for("tarsis_3").filter(
			func(p: Dictionary) -> bool: return float(p.get("radius_m", 0.0)) > 0.0)
	assert_eq(excl.size(), with_radius.size())
	assert_eq(PlanetTerrain.poi_crack_exclusions("no_such_body"), [])
