extends GutTest

## The canyons on the star chart. They are not in a body's tiles: the game carves them as it builds a
## chunk, and refuses to where the mesh is too coarse to hold one. The chart asked for them at every
## tile and was refused at every vertex — its finest mesh steps 265 m, a canyon of Tarsis III is 250 m
## wide. Near the ground it now cuts its tiles fine enough to carve them; higher up it draws the network
## as lines.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_canyons.gd

const BODY: String = "tarsis_3"
const RADIUS: float = 6356000.0
const RES: int = StarMapGround.GRID_RES

var _data: PlanetData = null


## Prepared once, before any test: see test_star_map_tiles.gd.
func before_all() -> void:
	_data = StarMapTiles.offline_data(BODY)


func _no_planet() -> bool:
	if _data == null or not _data.corundum_default_biome:
		pending("pas de PlanetData ou de tuiles %s sur cette machine" % BODY)
		return true
	return false


## Tiles of [param nside] along a line leaving the first town, a tile's width at a time: somewhere to
## look for a canyon that does not depend on knowing where one is.
func _tiles_leaving_town(nside: int, count: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	var pois: Array[Dictionary] = StarMapPoi.load_for(BODY)
	if pois.is_empty():
		return out
	var from: Vector3 = pois[0]["dir"]
	var sideways: Vector3 = from.cross(Vector3.UP).normalized()
	var step: float = HEALPix.pixel_side_length(nside, 1.0)
	for n: int in range(1, count + 1):
		var ipix: int = HEALPix.vec2pix_nest(nside, (from + sideways * (step * float(n))).normalized())
		if not out.has(ipix):
			out.append(ipix)
	return out


# ---------------------------------------------------------------------------
# How fine the ground must be cut
# ---------------------------------------------------------------------------

func test_the_ground_is_cut_as_fine_as_a_canyon_needs() -> void:
	assert_eq(StarMapRelief.detail_nside_for(1024, RADIUS, 250.0), 4096,
		"265 m a step at n1024, 132 at n2048, 66 at n4096: the first under half of 250 m")
	assert_eq(StarMapRelief.detail_nside_for(1024, RADIUS, 1000.0), 1024,
		"canyons a kilometre wide already fit the published level")
	assert_eq(StarMapRelief.detail_nside_for(1024, RADIUS, 5.0), 1024,
		"too narrow to reach in a few levels: the published level, not a runaway")
	assert_eq(StarMapRelief.detail_nside_for(1024, RADIUS, 0.0), 1024, "no canyons, no detail")


func test_the_walk_goes_past_the_published_level_only_when_told() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	var over: Vector3 = Vector3(0.3, 0.2, 0.9).normalized()
	var plain: Dictionary = StarMapRelief.patch_for(manifest, over, 1500.0, RADIUS, -1.0, 1024)
	assert_eq(int(plain["ceiling"]), 1024, "as before")
	var fine: Dictionary = StarMapRelief.patch_for(manifest, over, 1500.0, RADIUS, -1.0, 4096, 4096)
	assert_eq(int(fine["level"]), 4096, "a kilometre and a half up, the tile under the camera is a fine one")
	var high: Dictionary = StarMapRelief.patch_for(manifest, over, 300000.0, RADIUS, -1.0, 4096, 4096)
	assert_lt(int(high["level"]), 4096, "from three hundred km the planet's rule asks for nothing of the kind")


func test_a_fine_tile_answers_to_its_published_ancestor() -> void:
	var finest: int = StarMapRelief.finest_nside(BODY)
	if finest <= StarMapRelief.TILE_NSIDE:
		pending("pas de manifeste %s" % BODY)
		return
	var ipix: int = 123456
	var fine: int = StarMapGround.tile_id(finest * 4, ipix)
	assert_eq(StarMapRelief.published_id(BODY, fine), StarMapGround.tile_id(finest, ipix >> 4),
		"two levels up in nested order")
	var own: int = StarMapGround.tile_id(finest, 77)
	assert_eq(StarMapRelief.published_id(BODY, own), own, "a published tile is itself")
	assert_eq(StarMapRelief.published(BODY, {fine: true, StarMapGround.tile_id(finest * 4, ipix + 1): true}).size(),
		1, "siblings fold onto one ancestor: the roads of a tile are laid once")


# ---------------------------------------------------------------------------
# Near the ground: relief
# ---------------------------------------------------------------------------

func test_a_fine_tile_carries_the_game_s_canyons() -> void:
	if _no_planet():
		return
	var level: int = StarMapRelief.detail_nside(BODY)
	assert_gt(level, StarMapRelief.finest_nside(BODY), "this body's canyons need more than it publishes")
	var pitch: float = StarMapRelief.tile_pitch(_data.radius, level)
	for ipix: int in _tiles_leaving_town(level, 80):
		var mesh: ArrayMesh = StarMapRelief.build_tile(BODY, level, ipix, RES)
		if mesh == null:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(level, ipix, RES)
		var deepest: float = 0.0
		var floor_at: int = -1
		var rim_at: int = -1
		for vy: int in range(1, RES):
			for vx: int in range(1, RES):
				var at: int = vy * (RES + 1) + vx
				var drawn: float = (points[at].length() / StarMapRelief.MESH_RADIUS - 1.0) * _data.radius
				var whole: float = _data.sample_height_for_direction(grid[vy][vx], -1, -1,
						Vector2i(-1, -1), null, level, null, pitch, CrackCarve.NONE)
				if drawn - whole < deepest:
					deepest = drawn - whole
					floor_at = at
				elif absf(drawn - whole) < 1.0:
					rim_at = at
		if floor_at < 0 or rim_at < 0:
			continue  # solid block, or a town's sphere: the next tile along
		assert_almost_eq(deepest, -_data.crack_depth_m, 1.0, "the floor stands a full canyon's depth down")
		assert_eq(int(mesh.get_meta("source_nside", 0)), level,
			"and the tile is final: it is not waiting for data nobody publishes")
		assert_lt(colours[floor_at].get_luminance(), colours[rim_at].get_luminance() * 0.7,
			"the floor is drawn in shadow")
		return
	pending("aucun canyon sous les tuiles essayees de %s" % BODY)


func test_the_published_level_is_left_as_it_was() -> void:
	if _no_planet():
		return
	var level: int = StarMapRelief.finest_nside(BODY)
	var ipix: int = _tiles_leaving_town(level, 3)[2]
	var mesh: ArrayMesh = StarMapRelief.build_tile(BODY, level, ipix, RES)
	if mesh == null:
		pending("tuile n%d absente de cette machine" % level)
		return
	var points: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var pitch: float = StarMapRelief.tile_pitch(_data.radius, level)
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(level, ipix, RES)
	var worst: float = 0.0
	for vy: int in range(1, RES):
		for vx: int in range(1, RES):
			var drawn: float = (points[vy * (RES + 1) + vx].length() / StarMapRelief.MESH_RADIUS - 1.0) \
					* _data.radius
			worst = maxf(worst, absf(drawn - _data.sample_height_for_direction(grid[vy][vx], -1, -1,
					Vector2i(-1, -1), null, level, null, pitch, CrackCarve.NONE)))
	assert_lt(worst, 1.0, "too coarse for a canyon: none is drawn, as the game would have it")


# ---------------------------------------------------------------------------
# From higher up: lines
# ---------------------------------------------------------------------------

func test_the_network_shows_only_while_its_blocks_can_be_told_apart() -> void:
	assert_eq(StarMapCanyons.strength(4000.0, 100.0), 1.0, "forty pixels to a block: drawn in full")
	assert_eq(StarMapCanyons.strength(4000.0, 1000.0), 0.0, "four pixels to a block: a grey wash, not drawn")
	var between: float = StarMapCanyons.strength(4000.0, 400.0)
	assert_true(between > 0.0 and between < 1.0, "fading in between")
	assert_eq(StarMapCanyons.strength(0.0, 100.0), 0.0, "no network")


func test_lines_are_for_the_tiles_the_ground_draws_flat() -> void:
	if _no_planet():
		return
	var finest: int = StarMapRelief.finest_nside(BODY)
	assert_true(StarMapCanyons.traces(_data, finest), "the finest published level carries no canyon: traced")
	assert_false(StarMapCanyons.traces(_data, StarMapRelief.detail_nside(BODY)),
		"a tile that carves them needs no line over them")
	assert_false(StarMapCanyons.traces(_data, 16), "a tile four hundred km across is not traced at all")


## Three canyons meeting inside one square of the grid are drawn from the place they meet. Drawn from
## the middle of the square, they reached it from the wrong angles and the network did not join.
func test_a_fork_is_drawn_where_its_three_blocks_meet() -> void:
	# A flat square at z = 1, read where it stands, and three feature points round it.
	var grid: Array[PackedVector3Array] = [
		PackedVector3Array([Vector3(0, 0, 1), Vector3(1, 0, 1)]),
		PackedVector3Array([Vector3(0, 1, 1), Vector3(1, 1, 1)])]
	var read_at := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)])
	var a := Vector3(-0.2, -0.1, 0)
	var b := Vector3(1.3, 0.0, 0)
	var c := Vector3(0.4, 1.5, 0)
	var fork: Vector3 = StarMapCanyons._fork(grid, read_at, PackedVector3Array([a, b, c, c]), 0, 0, 2)
	var at := Vector3(fork.x / fork.z, fork.y / fork.z, 0)
	assert_almost_eq(at.distance_to(a), at.distance_to(b), 1.0e-6, "as far from the first block as the second")
	assert_almost_eq(at.distance_to(a), at.distance_to(c), 1.0e-6, "and as the third")
	assert_eq(StarMapCanyons._fork(grid, read_at, PackedVector3Array([a, b, a, b]), 0, 0, 2), Vector3.ZERO,
		"two blocks make a canyon, not a fork")


func test_the_lines_run_where_the_canyons_are() -> void:
	if _no_planet():
		return
	var level: int = 256
	var noise: CrackNoise = _data.crack_noise()
	var half: float = _data.crack_width_m * 0.5
	# Far enough to leave the massif the first town stands in: a mountain is not cut by the plateau's
	# canyons, and the tiles over it are rightly empty.
	for ipix: int in _tiles_leaving_town(level, 60):
		var laid: Array = StarMapCanyons.trace_tile(_data, level, ipix)
		var points: PackedVector3Array = laid[0]
		if points.size() < 20:
			continue
		assert_eq(points.size() % 2, 0, "segments: two ends each")
		assert_eq((laid[1] as PackedColorArray).size(), points.size(), "a colour for each end")
		var on_a_canyon: int = 0
		for p: Vector3 in points:
			if ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(p.normalized(), _data.radius,
					_data.crack_spacing_m, _data.crack_width_m, 0.0, noise) < half:
				on_a_canyon += 1
		# Forks included: the three stretches of one meet where the canyons do, not at the middle of
		# their square of the grid, which left the network in pieces that did not join.
		assert_gt(float(on_a_canyon) / float(points.size()), 0.9,
			"nine ends in ten stand inside a canyon")
		# And none where the game leaves the ground whole: a town's sphere is not cut.
		for n: int in range(0, points.size(), 2):
			var along: Vector3 = (points[n] + points[n + 1]).normalized()
			assert_gte(CrackCarve.depth_factor(_data, along, null), 0.5,
				"every stretch drawn is on ground the game carves")
		# Each stretch is also a strip as wide as the canyon it stands for.
		var corners: PackedVector3Array = laid[2]
		assert_eq(corners.size(), points.size() * 3, "two triangles a stretch")
		assert_eq((laid[3] as PackedColorArray).size(), corners.size(), "a colour for each corner")
		var wide: float = corners[0].normalized().angle_to(corners[1].normalized()) * _data.radius
		assert_almost_eq(wide, _data.crack_width_m, 1.0, "as wide as the canyon")
		return
	pending("aucun canyon sous les tuiles essayees de %s" % BODY)
