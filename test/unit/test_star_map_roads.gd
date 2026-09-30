extends GutTest

## The ways drawn over a body's ground: roads, tracks and railways, read from the terrain's own
## modifier pack.
##
## The pack is the same file the game carves its road beds from, so what is pinned here is mostly that
## the chart reads it the way the terrain does — the same tiles, the same degrees, the same ground.
##
## Depends on an export being present, which is a fact about the checkout rather than about the code;
## where it is missing these report as pending.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_roads.gd

const BODY: String = "tarsis_3"


## Prepare the body's PlanetData once, before any test: it prints as it opens its manifest and packs,
## and on a machine whose C# build lacks its dependency assemblies every print throws inside the
## OpenTelemetry bridge — which GUT would pin on whichever test happened to prepare it first.
func before_all() -> void:
	StarMapTiles.offline_data(BODY)


func _roads(key: String = BODY) -> StarMapRoads:
	var node := StarMapRoads.new()
	node.body_key = key
	add_child_autofree(node)
	return node


## The tiles around a place known to have ways through it, keyed as StarMapGround keys them.
func _tiles_around(label: String, nside: int) -> Dictionary:
	var out: Dictionary = {}
	for poi: Dictionary in StarMapPoi.load_for(BODY):
		if str(poi["label"]) != label:
			continue
		var here: int = HEALPix.vec2pix_nest(nside, poi["dir"])
		out[StarMapGround.tile_id(nside, here)] = true
		for key: Variant in HEALPix.get_neighbors_nest(nside, here).values():
			if int(key) >= 0:
				out[StarMapGround.tile_id(nside, int(key))] = true
	return out


# ---------------------------------------------------------------------------

## A body with no pack draws nothing, and that is an ordinary answer: most of them have none.
func test_a_body_without_a_pack_draws_nothing() -> void:
	var roads: StarMapRoads = _roads("no_such_body")
	roads.refresh({StarMapGround.tile_id(1, 0): true})
	assert_null(roads.mesh, "nothing to draw, and nothing to complain about")


## And an empty request draws nothing either, rather than the whole body.
func test_no_tiles_means_no_ways() -> void:
	var roads: StarMapRoads = _roads()
	roads.refresh({})
	assert_null(roads.mesh)


## Around a village the pack has ways, and they come out as line segments on the ground.
func test_the_ways_around_a_village_are_drawn() -> void:
	var tiles: Dictionary = _tiles_around("Mining village 01", 64)
	if tiles.is_empty():
		pending("pas de POI %s dans cet export" % BODY)
		return
	var roads: StarMapRoads = _roads()
	roads.refresh(tiles)
	roads.finish()
	if roads.mesh == null:
		pending("aucun pack de modificateurs pour %s sur cette machine" % BODY)
		return
	var arrays: Array = (roads.mesh as ArrayMesh).surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_gt(points.size(), 1, "there are ways around the mining villages")
	assert_eq(points.size() % 2, 0, "line segments come in pairs")
	assert_eq(colours.size(), points.size(), "one colour per vertex, or the surface is rejected")
	# On the ground, not on the reference sphere: the lift is a fraction of a percent, so a point that
	# ignored the relief would sit outside this band on a body whose ground runs from 0.997 to 1.010.
	for p: Vector3 in points:
		var factor: float = p.length() / StarMapRelief.MESH_RADIUS
		assert_between(factor, 0.99, 1.02, "every point of a way stands on the body's own ground")


## Asking twice for the same tiles does nothing the second time.
##
## The tiles come from a decision taken four times a second at most, while this runs every frame, and
## reading a pack is disk work. Pinned by identity: an unchanged view has to keep the very same mesh,
## not an equal one built again.
func test_an_unchanged_view_is_not_redrawn() -> void:
	var tiles: Dictionary = _tiles_around("Mining village 01", 64)
	if tiles.is_empty():
		pending("pas de POI %s dans cet export" % BODY)
		return
	var roads: StarMapRoads = _roads()
	roads.refresh(tiles)
	roads.finish()
	var first: Mesh = roads.mesh
	if first == null:
		pending("aucun pack de modificateurs pour %s sur cette machine" % BODY)
		return
	roads.refresh(tiles.duplicate())
	assert_true(roads.mesh == first, "the same tiles, so the same mesh, untouched")


## Every kind of way the pack can name has a colour of its own. A railway that came out the same
## colour as a road would be worth no more than not drawing it.
func test_each_kind_of_way_is_told_apart() -> void:
	var seen: Dictionary = {}
	for kind: String in StarMapRoads.COLOURS:
		var tint: Color = StarMapRoads.COLOURS[kind]
		assert_false(seen.has(tint), "%s has a colour of its own" % kind)
		seen[tint] = true
	assert_true(StarMapRoads.COLOURS.has("railway"), "a railway is not a road")
	assert_false(seen.has(StarMapRoads.UNKNOWN_COLOUR),
			"and a kind nobody has named yet is told apart from all of them")


# ---------------------------------------------------------------------------
# Lines that stay on the ground they are drawn over
# ---------------------------------------------------------------------------

## A point on the unit sphere, as a line's "ground" for the tests below.
func _flat(dir: Vector3) -> Vector3:
	return dir


## The railway seen from six hundred km was a row of dashes: the export gives it across a hundred-km
## tile in a handful of points, and a straight line between two of them runs under the curve of the
## planet. No piece is now longer than a step of the mesh it lies on.
func test_a_long_stretch_is_cut_to_the_step_of_the_mesh() -> void:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	var from := Vector3(0, 0, 1)
	var to := Vector3(sin(0.1), 0, cos(0.1))
	StarMapTileLines.add_line(points, colours, from, to, 0.01, _flat, Color.WHITE)
	assert_eq(points.size(), 20, "ten pieces, two ends each")
	assert_eq(colours.size(), points.size())
	assert_almost_eq(points[0].distance_to(from), 0.0, 1.0e-9, "from the first point")
	assert_almost_eq(points[19].distance_to(to), 0.0, 1.0e-9, "to the last")
	for n: int in range(0, points.size(), 2):
		assert_almost_eq(points[n].length(), 1.0, 1.0e-9, "every end is on the ground, none under it")
		assert_lt(points[n].angle_to(points[n + 1]), 0.0101, "and no piece is longer than the step")
	points.clear()
	colours.clear()
	StarMapTileLines.add_line(points, colours, from, Vector3(sin(0.004), 0, cos(0.004)), 0.01, _flat, Color.WHITE)
	assert_eq(points.size(), 2, "a stretch shorter than a step is left as it is")


## The sleepers were counted off from the start of each piece of railway, and a railway reaches the
## chart cut at every tile edge: the gap at each edge came out any length. And their two ends were put
## on the ground one by one, so a sleeper on a slope was longer than its neighbours.
func test_sleepers_are_evenly_spread_and_all_the_same_length() -> void:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	var step: float = 0.01
	# A piece with a bend in it, 0.10 long: round(0.10 / 0.03) = 3 sleepers, 0.0333 apart.
	var way := PackedVector3Array([Vector3(0, 0, 1), Vector3(sin(0.04), 0, cos(0.04)),
			Vector3(sin(0.04), 0, cos(0.04)).rotated(Vector3.RIGHT, -0.06)])
	# Ground that slopes: higher to one side of the line than the other.
	var sloping: Callable = func(dir: Vector3) -> Vector3: return dir * (1.0 + dir.y * 0.5)
	StarMapRoads.add_sleepers(points, colours, way, step, sloping, Color.WHITE)
	assert_eq(points.size(), 6, "three sleepers, two ends each")
	assert_eq(colours.size(), points.size())
	var walked: Array[float] = []
	for n: int in range(0, points.size(), 2):
		assert_almost_eq(points[n].normalized().angle_to(points[n + 1].normalized()),
				2.0 * step * StarMapRoads.SLEEPER_HALF, 1.0e-6, "each a step and a half long")
		assert_almost_eq(points[n].length(), points[n + 1].length(), 1.0e-9,
			"and level: both ends at the height of the line, whatever the ground does to either side")
		var middle: Vector3 = (points[n].normalized() + points[n + 1].normalized()).normalized()
		var along: float = way[0].angle_to(middle) if n == 0 else 0.04 + way[1].angle_to(middle)
		walked.append(along)
	assert_almost_eq(walked[0], 0.10 / 6.0, 1.0e-4, "the first half a gap in from the start")
	assert_almost_eq(walked[1] - walked[0], 0.10 / 3.0, 1.0e-4, "then a gap apart, round the bend too")
	assert_almost_eq(walked[2] - walked[1], 0.10 / 3.0, 1.0e-4)
	assert_almost_eq(0.10 - walked[2], 0.10 / 6.0, 1.0e-4,
		"and the last half a gap from the end: with the next tile's half, a whole one")
	points.clear()
	colours.clear()
	StarMapRoads.add_sleepers(points, colours, PackedVector3Array([way[0], Vector3(sin(0.01), 0, cos(0.01))]),
			step, sloping, Color.WHITE)
	assert_eq(points.size(), 0, "a piece shorter than half a gap carries none")


func test_one_size_of_sleeper_for_a_whole_view() -> void:
	assert_almost_eq(StarMapRoads.mesh_step(64), StarMapRoads.mesh_step(32) * 0.5, 1.0e-12,
		"a level finer, half the step: tile by tile, the sleepers doubled at every ring of the view")
	assert_eq(StarMapRoads.mesh_step(0), 0.0, "no level yet, no size: each tile falls back on its own")

## A point between four vertices is put on the facet the mesh draws there, not on the true ground,
## which can stand hundreds of metres off it at a coarse level.
func test_a_point_is_put_on_the_facet_the_mesh_draws() -> void:
	# Corners 00, 10, 01, 11. The flatter diagonal is 10-01 (both at 100): the fold runs along it.
	assert_eq(StarMapDrawnTile.facet_height(0.0, 100.0, 100.0, 400.0, 0.0, 0.0), 0.0, "a corner is itself")
	assert_eq(StarMapDrawnTile.facet_height(0.0, 100.0, 100.0, 400.0, 1.0, 1.0), 400.0)
	assert_eq(StarMapDrawnTile.facet_height(0.0, 100.0, 100.0, 400.0, 0.5, 0.5), 100.0,
		"the middle lies ON the fold: 100, where a bilinear reading would say 150")
	# The other diagonal when that one is the flatter: 00-11 both at 0.
	assert_eq(StarMapDrawnTile.facet_height(0.0, 300.0, 100.0, 0.0, 0.5, 0.5), 0.0, "on the fold again")
	assert_eq(StarMapDrawnTile.facet_height(0.0, 300.0, 100.0, 0.0, 1.0, 0.0), 300.0)
	assert_eq(StarMapDrawnTile.facet_height(0.0, 300.0, 100.0, 0.0, 0.0, 1.0), 100.0)