extends GutTest

## How the star chart cuts a body's ground: by the PLANET's own rule ([PlanetLod]), fine under the
## camera and coarser ring by ring, so that a ship arriving at a planet sees the chart's ground divided
## the way the real ground will be.
##
## It used to spend a fixed tile budget on one level for the whole view instead. Everything here is
## HEALPix arithmetic and a manifest, so it holds on a checkout that has never run the game.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_lod.gd

const RADIUS: float = 6356000.0
const MANIFEST: Dictionary = {"nside_max": 1024, "radius": RADIUS}
## Heights from across the system down to the ground, metres.
const DESCENT: Array[float] = [2.0e7, 3.6e6, 3.0e5, 3.0e4, 4.0e3, 1.0e3, 1.0]


func _plan(altitude: float, dir: Vector3 = Vector3.UP, view: float = -1.0,
		manifest: Dictionary = MANIFEST) -> Dictionary:
	return StarMapRelief.patch_for(manifest, dir, altitude, RADIUS, view)


## THE claim: for the same camera, the chart asks for exactly the tiles the planet would.
##
## Checked against PlanetTerrain._traverse itself, on the server path (no culling), with the chart's
## own culling opened to the whole sphere — so what is compared is the cutting rule and nothing else.
func test_the_chart_cuts_its_ground_as_the_planet_does() -> void:
	var terrain := PlanetTerrain.new()
	terrain.planet_data = PlanetData.new()
	terrain.planet_data.radius = RADIUS
	terrain.planet_data.max_quadtree_depth = 8
	terrain.is_server = true
	for altitude: float in [3.0e5, 3.0e4, 1.0e3]:
		var cam: Vector3 = Vector3(0.3, 0.8, -0.5).normalized()
		var lod_pass := terrain._new_pass(cam * (RADIUS + altitude), -1.0, {}, false)
		lod_pass.alt = altitude  # what the traversal reads (frozen when it starts)
		for base: int in range(12):
			terrain._traverse(lod_pass, 1, base, 0)
		var planet: Dictionary = lod_pass.out
		var theirs: Dictionary = {}
		for key: String in planet:
			theirs[StarMapGround.tile_id(int(planet[key]["nside"]), int(planet[key]["ipix"]))] = true
		var ours := PackedInt64Array()
		for base: int in range(12):
			StarMapRelief._quadtree(1, base, cam, altitude, RADIUS, PI * 2.0, 1 << 8, ours)
		assert_eq(ours.size(), theirs.size(), "at %.0f km, as many tiles" % (altitude / 1000.0))
		var missing: int = 0
		for id: int in ours:
			if not theirs.has(id):
				missing += 1
		assert_eq(missing, 0, "at %.0f km, and the very same ones" % (altitude / 1000.0))
	terrain.free()


## Coming closer buys detail under the camera, and never takes it away.
func test_the_ground_gets_finer_under_the_camera_as_it_descends() -> void:
	var last: int = 0
	for altitude: float in DESCENT:
		var level: int = int(_plan(altitude)["level"])
		assert_gte(level, last, "at %.0f m, never coarser for being closer" % altitude)
		last = level
	assert_eq(last, 1024, "and on the deck, the finest level the body publishes")


## What comes back is a partition: no tile drawn over another, and the ground under the camera covered.
##
## A tile and one of its own descendants both wanted would be two surfaces on the same ground, shimmering
## against each other for as long as the view stays.
func test_the_tiles_never_overlap_and_cover_the_ground_underfoot() -> void:
	for altitude: float in DESCENT:
		var tiles: PackedInt64Array = _plan(altitude)["tiles"]
		var wanted: Dictionary = {}
		for id: int in tiles:
			wanted[id] = true
		var stacked: int = 0
		for id: int in tiles:
			var nside: int = StarMapGround.id_nside(id)
			var ipix: int = StarMapGround.id_ipix(id)
			while nside > 1:
				nside /= 2
				ipix = ipix >> 2
				if wanted.has(StarMapGround.tile_id(nside, ipix)):
					stacked += 1
		assert_eq(stacked, 0, "at %.0f m, no tile over another" % altitude)
		var under: int = int(_plan(altitude)["level"])
		assert_true(wanted.has(StarMapGround.tile_id(under, HEALPix.vec2pix_nest(under, Vector3.UP))),
				"at %.0f m, the ground under the camera is drawn" % altitude)


## And it stays within what a worker pool can build, all the way down.
##
## Measured over the pole with a 57.8° field of view: 8 tiles from 20 000 km, 128 at 3 600 km, 112 at
## 300 km, 132 at 30 km, 12 at 4 km, 4 at 1 km — the rule, not the guard, decides at every height a
## player actually uses.
func test_the_view_stays_within_the_guard() -> void:
	var half_fov: float = deg_to_rad(57.8)
	for altitude: float in DESCENT:
		var view: float = StarMapRelief.view_half_angle(RADIUS + altitude, RADIUS, half_fov)
		var plan: Dictionary = _plan(altitude, Vector3.UP, view)
		var count: int = (plan["tiles"] as PackedInt64Array).size()
		assert_gt(count, 0, "at %.0f m, something to draw" % altitude)
		assert_lte(count, StarMapRelief.PATCH_TILES_MAX, "at %.0f m, within the guard" % altitude)
	var near: Dictionary = _plan(1.0e3, Vector3.UP,
			StarMapRelief.view_half_angle(RADIUS + 1.0e3, RADIUS, half_fov))
	assert_eq(int(near["ceiling"]), 1024, "at 1 km the rule decides, not the guard")


## Over a pole too. HEALPix pixels are diamonds whose corners are far from equidistant there, and a
## cull on half the diagonal threw away the very pixel under a camera parked over the north pole.
func test_the_poles_have_ground_too() -> void:
	for dir: Vector3 in [Vector3.UP, Vector3.DOWN, Vector3(0.3, 0.8, -0.5).normalized()]:
		for altitude: float in [3.0e4, 1.0e3]:
			assert_gt((_plan(altitude, dir)["tiles"] as PackedInt64Array).size(), 0,
					"%s at %.0f m" % [str(dir), altitude])


## Nothing is asked for beyond what the camera can see.
func test_nothing_is_wanted_beyond_the_horizon() -> void:
	for altitude: float in [3.0e5, 3.0e4, 1.0e3]:
		var horizon: float = StarMapRelief.horizon_angle(altitude, RADIUS)
		for id: int in (_plan(altitude)["tiles"] as PackedInt64Array):
			var nside: int = StarMapGround.id_nside(id)
			var ipix: int = StarMapGround.id_ipix(id)
			var half: float = StarMapRelief.pixel_reach(nside, ipix)
			assert_lte(HEALPix.pix2vec_nest(nside, ipix).angle_to(Vector3.UP), horizon + half + 1.0e-6,
					"at %.0f km, n%d f%d lies beyond the horizon" % [altitude / 1000.0, nside, ipix])


## Bounding by what the screen shows costs fewer tiles, never more, and changes nothing far out.
func test_bounding_by_the_view_only_ever_saves_tiles() -> void:
	var half_fov: float = deg_to_rad(57.8)
	var saved: int = 0
	for altitude: float in [4.0e5, 2.24e5, 3.0e4, 1.0e3]:
		var view: float = StarMapRelief.view_half_angle(RADIUS + altitude, RADIUS, half_fov)
		var blind: int = (_plan(altitude)["tiles"] as PackedInt64Array).size()
		var seeing: int = (_plan(altitude, Vector3.UP, view)["tiles"] as PackedInt64Array).size()
		assert_lte(seeing, blind, "at %.0f km, never more for knowing more" % (altitude / 1000.0))
		if seeing < blind:
			saved += 1
	assert_gt(saved, 1, "and fewer at most of those heights, which is the point")
	for altitude: float in [3.0e6, 2.0e7]:
		var view: float = StarMapRelief.view_half_angle(RADIUS + altitude, RADIUS, half_fov)
		assert_eq(_plan(altitude, Vector3.UP, view)["tiles"], _plan(altitude)["tiles"],
				"at %.0f km the whole body is in frame, so nothing is bounded" % (altitude / 1000.0))


## No near view, no cut: the whole globe. A body seen from across the system has no ground under the
## camera to centre anything on.
func test_no_near_view_means_the_whole_globe() -> void:
	for plan: Dictionary in [_plan(500.0, Vector3.ZERO), _plan(-1.0)]:
		assert_eq(int(plan["level"]), 1)
		assert_eq((plan["tiles"] as PackedInt64Array).size(), 12, "the twelve tiles of the whole sphere")


## A body that publishes only the coarsest level is never asked for more, however close you get.
func test_a_body_that_publishes_nothing_fine_is_never_asked_for_it() -> void:
	var plan: Dictionary = _plan(100.0, Vector3.UP, -1.0, {"nside_max": 1, "radius": RADIUS})
	assert_eq(int(plan["level"]), 1, "nside_max is a ceiling, and a metre off the ground does not lift it")
	for id: int in (plan["tiles"] as PackedInt64Array):
		assert_eq(StarMapGround.id_nside(id), 1)


## And a cap on the depth — what the chart knows of the ground — is honoured the same way.
func test_the_cap_bounds_every_tile() -> void:
	var plan: Dictionary = StarMapRelief.patch_for(MANIFEST, Vector3.UP, 1.0, RADIUS, -1.0, 16)
	assert_eq(int(plan["level"]), 16)
	for id: int in (plan["tiles"] as PackedInt64Array):
		assert_lte(StarMapGround.id_nside(id), 16)
