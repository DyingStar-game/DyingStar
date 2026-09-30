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


func test_a_railway_carries_sleepers_evenly_round_a_bend() -> void:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	var step: float = 0.01
	var a := Vector3(0, 0, 1)
	var b := Vector3(sin(0.05), 0, cos(0.05))
	var left: float = StarMapRoads._add_sleepers(points, colours, a, b, step, 0.0, _flat, Color.WHITE)
	assert_eq(points.size(), 2, "one every three steps: 0.03 along a stretch of 0.05")
	assert_almost_eq(left, 0.02, 1.0e-9, "and 0.02 run since")
	var middle: Vector3 = (points[0] + points[1]).normalized()
	assert_almost_eq(middle.angle_to(a), 0.03, 1.0e-9, "on the line")
	assert_almost_eq(points[0].angle_to(points[1]), 2.0 * step * StarMapRoads.SLEEPER_HALF, 1.0e-6,
		"a step and a half long")
	assert_almost_eq(absf((points[1] - points[0]).normalized().dot((b - a).normalized())), 0.0, 1.0e-6,
		"across it")
	StarMapRoads._add_sleepers(points, colours, b, Vector3(sin(0.08), 0, cos(0.08)), step, left, _flat, Color.WHITE)
	assert_eq(points.size(), 4, "the next stretch places its first 0.01 in, not a whole interval")
	assert_almost_eq((points[2] + points[3]).normalized().angle_to(a), 0.06, 1.0e-9)


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