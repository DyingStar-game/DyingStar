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
	# The mesh is laid around its own middle (float32 precision): back to the body frame first.
	var origin: Vector3 = roads.position / roads.scale.x
	assert_gt(origin.length(), 0.5 * StarMapRelief.MESH_RADIUS, "the mesh is laid around its ground, not the centre")
	for p: Vector3 in points:
		var factor: float = (p + origin).length() / StarMapRelief.MESH_RADIUS
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


## The signs were sized on a step of the ground's mesh, reckoned at five pixels; a step is anything from
## three to twenty, and the tunnels came out five times too wide. They are sized in pixels.
func test_a_sign_is_a_few_pixels_at_every_scale() -> void:
	var radius: float = 6356000.0
	for metres_per_pixel: float in [3.0, 40.0, 850.0, 20000.0]:
		var pixels: float = StarMapRoads.sign_length(metres_per_pixel, radius) * radius / metres_per_pixel
		assert_between(pixels, StarMapRoads.SIGN_PIXELS / 1.5, StarMapRoads.SIGN_PIXELS * 1.5,
			"%.0f m to the pixel" % metres_per_pixel)
	assert_eq(StarMapRoads.sign_length(40.0, radius), StarMapRoads.sign_length(44.0, radius),
		"and the same over a small change of scale: the ways are not laid again at every notch")
	assert_eq(StarMapRoads.sign_length(0.0, radius), 0.0, "no scale yet, no size: each tile falls back on its own")


## A line through a massif is a tunnel, a cutting, a tunnel: as many signs end to end read as a saw
## blade. Close ones are drawn as one, and come apart as the view comes down.
func test_tunnels_close_together_are_drawn_as_one() -> void:
	var spans: Array = [Vector2(900.0, 1000.0), Vector2(0.0, 300.0), Vector2(350.0, 600.0), Vector2(5000.0, 5020.0)]
	assert_eq(StarMapRoads.join_spans(spans, 400.0, 100.0), [Vector2(0.0, 1000.0)] as Array[Vector2],
		"from high up: three within 400 m of one another make one, and 20 m on its own is not marked")
	assert_eq(StarMapRoads.join_spans(spans, 100.0, 10.0),
		[Vector2(0.0, 600.0), Vector2(900.0, 1000.0), Vector2(5000.0, 5020.0)] as Array[Vector2],
		"lower: the pair 50 m apart still one, the others on their own")
	assert_eq(StarMapRoads.join_spans(spans, 20.0, 10.0).size(), 4, "lower still: every one of them")

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

# ---------------------------------------------------------------------------
# Tunnels
# ---------------------------------------------------------------------------

## A way 1 000 m long along the equator, in two points, as one tile would hold it.
const WAY: Array[Vector3] = [Vector3(0, 0, 1), Vector3(0.0998334166, 0, 0.9950041653)]


func _way() -> PackedVector3Array:
	return PackedVector3Array(WAY)


## A way under a mountain was drawn over it like any other. It now carries a dark line either side for
## as long as it is in the tunnel, splayed at each mouth.
func test_a_tunnel_is_a_line_either_side_of_the_way_splayed_at_its_mouths() -> void:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	var step: float = 0.002
	StarMapRoads.add_span_signs(points, colours, _way(), PackedFloat64Array([0.0, 1000.0]),
			[Vector2(250.0, 500.0)], step, 1.0, _flat, StarMapRoads.TUNNEL_COLOUR)
	assert_eq(points.size(), 12, "each side: its line and a splay at either mouth")
	for colour: Color in colours:
		assert_eq(colour, StarMapRoads.TUNNEL_COLOUR)
	var mouth: Vector3 = WAY[0].slerp(WAY[1], 0.25)
	var far_mouth: Vector3 = WAY[0].slerp(WAY[1], 0.5)
	assert_almost_eq(points[0].angle_to(mouth), step * StarMapRoads.SPAN_SIDE, 1.0e-6,
		"a side line starts beside the mouth, a little out from the way")
	assert_almost_eq(points[1].angle_to(far_mouth), step * StarMapRoads.SPAN_SIDE, 1.0e-6,
		"and ends beside the other")
	assert_almost_eq(points[0].y, -points[6].y, 1.0e-9, "the two sides stand either side of the way")
	# The splay at the first mouth: further from the way than the side line, and back out of the tunnel.
	assert_gt(absf(points[3].y), absf(points[2].y), "leaning out from the way")
	assert_lt(points[3].angle_to(WAY[0]), points[2].angle_to(WAY[0]), "and away from the tunnel")


func test_a_tunnel_running_on_into_the_next_tile_has_no_mouth_here() -> void:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	StarMapRoads.add_span_signs(points, colours, _way(), PackedFloat64Array([2000.0, 3000.0]),
			[Vector2(1500.0, 2400.0)], 0.002, 1.0, _flat, StarMapRoads.TUNNEL_COLOUR)
	assert_eq(points.size(), 8, "each side: its line, and one splay at the mouth that IS here")
	points.clear()
	colours.clear()
	StarMapRoads.add_span_signs(points, colours, _way(), PackedFloat64Array([2000.0, 3000.0]),
			[Vector2(100.0, 900.0), Vector2(3500.0, 3600.0)], 0.002, 1.0, _flat, StarMapRoads.TUNNEL_COLOUR)
	assert_eq(points.size(), 0, "a tunnel elsewhere on the line draws nothing on this piece")


func test_a_stretch_is_found_between_the_points_of_the_way() -> void:
	var inside: PackedVector3Array = StarMapRoads.stretch_of(_way(), PackedFloat64Array([0.0, 1000.0]),
			250.0, 500.0, 0.01)
	assert_eq(inside.size(), 4, "0.025 of arc in pieces no longer than 0.01: three of them")
	assert_almost_eq(inside[0].angle_to(WAY[0]), 0.025, 1.0e-9, "from 250 m along")
	assert_almost_eq(inside[3].angle_to(WAY[0]), 0.05, 1.0e-9, "to 500 m along")


## The tunnels and the bridges are the game's own: where a line's profile says it runs under the ground
## or over a viaduct, and where a way crosses a canyon.
func test_the_signs_drawn_are_the_spans_the_planet_knows() -> void:
	var data: PlanetData = StarMapTiles.offline_data(BODY)
	if data == null:
		pending("pas de PlanetData ou de tuiles %s sur cette machine" % BODY)
		return
	var profiles: Dictionary = data.known_grade_profiles()
	if profiles.is_empty():
		pending("pas de profils de ligne precalcules pour %s" % BODY)
		return
	var roads: StarMapRoads = add_child_autofree(StarMapRoads.new())
	roads.body_key = BODY
	var known: Dictionary = roads._known_spans(data)
	for sort: String in ["tunnels", "bridges"]:
		var count: int = 0
		for fid: int in known[sort]:
			for span: Vector2 in known[sort][fid]:
				assert_gt(span.y, span.x, "from one end to the other, in metres along the line")
				count += 1
		gut.p("%d %s on %d line(s) of %s" % [count, sort, (known[sort] as Dictionary).size(), BODY])
	assert_false((known["tunnels"] as Dictionary).is_empty(), "this planet's lines go through mountains")
	assert_true(roads._known_spans(data) == known, "and read once, not at every batch")


func test_a_short_span_is_not_marked_and_a_tunnel_has_a_bed() -> void:
	var points := PackedVector3Array()
	var colours := PackedColorArray()
	var beds := PackedVector3Array()
	StarMapRoads.add_span_signs(points, colours, _way(), PackedFloat64Array([0.0, 1000.0]),
			[Vector2(250.0, 500.0)], 0.002, 1.0, _flat, StarMapRoads.TUNNEL_COLOUR, 300.0, beds)
	assert_eq(points.size(), 0, "250 m of tunnel where 300 is the least worth a sign")
	assert_eq(beds.size(), 0)
	StarMapRoads.add_span_signs(points, colours, _way(), PackedFloat64Array([0.0, 1000.0]),
			[Vector2(250.0, 500.0)], 0.002, 1.0, _flat, StarMapRoads.TUNNEL_COLOUR, 200.0, beds)
	assert_eq(points.size(), 12, "marked once it is long enough")
	assert_eq(beds.size(), 6, "with its bed: one strip, two triangles")
	assert_almost_eq(beds[0].length(), points[0].length(), 1.0e-9,
		"at the height of the way: sunk under it, it went into the hillside wherever the ground rose")
	var widest: float = 0.0
	for corner: Vector3 in beds:
		widest = maxf(widest, absf(corner.normalized().y))
	assert_lt(widest, absf(points[0].normalized().y),
		"and between the two side lines, short of them: nothing lies over it but the way")

## From high up the tunnels and the bridges are detail the map does not need, and thirteen thousand
## canyon crossings a string of signs along every way: they are marked from some thirty km up.
func test_tunnels_and_bridges_are_marked_only_from_close_enough() -> void:
	assert_true(StarMapRoads.marks_spans(40.0), "forty metres to the pixel: marked")
	assert_true(StarMapRoads.marks_spans(StarMapRoads.SPANS_WITHIN), "and at the limit")
	assert_false(StarMapRoads.marks_spans(200.0), "two hundred: the ways alone")
	assert_false(StarMapRoads.marks_spans(0.0), "no scale yet: nothing marked")

# ---------------------------------------------------------------------------
# The streets inside a village
# ---------------------------------------------------------------------------

## A body's radius for the widths below, and the level the streets are laid at.
const STREET_RADIUS_M: float = 6.0e6
const STREET_NSIDE: int = 64


## A village road as PlanetData keeps it (register_village_roads): a hundred metres or so along a
## meridian, with the middle of its line.
func _village_road(kind: String, width_m: float) -> Dictionary:
	var line := PackedVector2Array([Vector2(10.0, 20.0), Vector2(10.0, 20.001)])
	var middle: Vector3 = (HEALPix.lonlat2vec(line[0].x, line[0].y)
			+ HEALPix.lonlat2vec(line[1].x, line[1].y)).normalized()
	return {"road_type": kind, "width": width_m, "centerline": line, "_dir": middle}


func _tile_of(road: Dictionary) -> int:
	return HEALPix.vec2pix_nest(STREET_NSIDE, road["_dir"])


## The pack holds no way inside a village: the map showed its buildings and not one street between
## them. The streets come from the village's own roads, and each is drawn ONCE, in the tile it stands in.
func test_a_village_road_is_drawn_in_the_tile_it_stands_in() -> void:
	var road: Dictionary = _village_road("road", 6.0)
	var here: int = _tile_of(road)
	var laid: Array = StarMapRoads.lay_village_roads([road], STREET_NSIDE, here, _flat, STREET_RADIUS_M)
	var points: PackedVector3Array = laid[0]
	var colours: PackedColorArray = laid[1]
	assert_gt(points.size(), 0, "a line, like every other way")
	assert_eq(points.size(), colours.size())
	assert_eq(colours[0], StarMapRoads.COLOURS["road"], "in a road's colour")
	var next_door: int = (here + 1) % (12 * STREET_NSIDE * STREET_NSIDE)
	var elsewhere: Array = StarMapRoads.lay_village_roads([road], STREET_NSIDE, next_door, _flat,
			STREET_RADIUS_M)
	assert_eq((elsewhere[0] as PackedVector3Array).size(), 0, "and not again in the tile next door")


## Among buildings drawn at their footprint, a street is drawn at its own width.
func test_a_village_road_is_as_wide_as_it_is() -> void:
	var road: Dictionary = _village_road("road", 6.0)
	var laid: Array = StarMapRoads.lay_village_roads([road], STREET_NSIDE, _tile_of(road), _flat,
			STREET_RADIUS_M)
	var strips: PackedVector3Array = laid[2]
	assert_eq(strips.size(), 6, "one stretch: two triangles")
	assert_eq((laid[3] as PackedColorArray).size(), strips.size(), "a colour for each corner")
	assert_almost_eq(strips[0].distance_to(strips[1]) * STREET_RADIUS_M, 6.0, 0.01, "six metres across")


## With no radius there is no telling an angle from a width: the line alone, rather than a wrong strip.
func test_without_a_radius_a_village_road_is_only_a_line() -> void:
	var road: Dictionary = _village_road("road", 6.0)
	var laid: Array = StarMapRoads.lay_village_roads([road], STREET_NSIDE, _tile_of(road), _flat, 0.0)
	assert_gt((laid[0] as PackedVector3Array).size(), 0)
	assert_eq((laid[2] as PackedVector3Array).size(), 0)


## A footpath is the other kind of way a village layout draws: its own colour, not the unknown one.
func test_a_village_path_is_told_from_a_road() -> void:
	var path: Dictionary = _village_road("path", 3.0)
	var laid: Array = StarMapRoads.lay_village_roads([path], STREET_NSIDE, _tile_of(path), _flat,
			STREET_RADIUS_M)
	assert_true(StarMapRoads.COLOURS.has("path"), "RoadSnap.KIND_NAMES names it")
	assert_eq((laid[1] as PackedColorArray)[0], StarMapRoads.COLOURS["path"])


## The map lays its lines again when the village roads change, and tells a change by the identity of
## PlanetData's array: that only holds while the array is replaced, never written in place.
func test_a_new_village_road_is_a_new_array() -> void:
	var data := PlanetData.new()
	data.radius = STREET_RADIUS_M
	data.max_quadtree_depth = 14
	data.relief_signature = "relief-test"
	var before: Array = data.village_roads()
	var line := PackedVector2Array([Vector2(10.0, 20.0), Vector2(10.0, 20.001)])
	data.register_village_roads("village:streets", [{"road_type": "road", "width": 6.0,
			"centerline": line, "_cum_lengths": PackedFloat64Array([0.0, 104.7]), "village": true,
			"bed": "village:streets", "feature_id": LayoutRoads.FEATURE_ID_BASE - 1, "_sink_m": 0.0}])
	assert_eq(data.village_roads().size(), 1)
	assert_false(is_same(before, data.village_roads()), "replaced whole: the chart sees the change")
	assert_true(data.village_roads()[0].has("_dir"), "each with the middle of its line")


## The streets are those of the planet as it stands LOADED, which the chart hands over. The PlanetData
## the heights are read through is, on a client, the chart's own copy of the scene's: it knows no
## village, and the map read from it drew no street at all (playtest 2026-11-20).
func test_the_streets_are_those_of_the_loaded_planet() -> void:
	assert_true(StarMapRoads.village_roads_of(null).is_empty(), "a body that is not loaded has none")
	var planet: Planet = autofree(Planet.new())
	assert_true(StarMapRoads.village_roads_of(planet).is_empty(), "nor has a body without data")
	var data := PlanetData.new()
	data.radius = STREET_RADIUS_M
	data.max_quadtree_depth = 14
	data.relief_signature = "relief-test"
	planet.planet_data = data
	var line := PackedVector2Array([Vector2(10.0, 20.0), Vector2(10.0, 20.001)])
	data.register_village_roads("village:streets", [{"road_type": "road", "width": 6.0,
			"centerline": line, "_cum_lengths": PackedFloat64Array([0.0, 104.7]), "village": true,
			"bed": "village:streets", "feature_id": LayoutRoads.FEATURE_ID_BASE - 1, "_sink_m": 0.0}])
	assert_true(is_same(StarMapRoads.village_roads_of(planet), data.village_roads()),
			"the very array the planet keeps: a change of it is a change here")


## And what the view is handed reaches the ground: a street is laid with the tile it stands in, at its
## width. From too high for the tunnels to be marked, so the only strip there can be is the street's.
func test_a_street_handed_to_the_view_is_drawn() -> void:
	var road: Dictionary = _village_road("road", 6.0)
	var tiles: Dictionary = {StarMapGround.tile_id(STREET_NSIDE, _tile_of(road)): true}
	var roads: StarMapRoads = _roads()
	roads.show_over(tiles, StarMapRoads.SPANS_WITHIN * 2.0, STREET_RADIUS_M, [road])
	roads.finish()
	if roads.mesh == null:
		pending("aucun pack de modificateurs pour %s sur cette machine" % BODY)
		return
	var strips: int = 0
	for surface: int in roads.mesh.get_surface_count():
		if (roads.mesh as ArrayMesh).surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES:
			strips += 1
	assert_eq(strips, 1, "the street, as a strip of its own width")
	var without: StarMapRoads = _roads()
	without.show_over(tiles, StarMapRoads.SPANS_WITHIN * 2.0, STREET_RADIUS_M)
	without.finish()
	var bare: int = 0
	if without.mesh != null:
		for surface: int in without.mesh.get_surface_count():
			if (without.mesh as ArrayMesh).surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES:
				bare += 1
	assert_eq(bare, 0, "and none when the view is handed no street")


## A way is ground: whatever stands on the chart is drawn over it. At the default priority the streets
## of a village crossed its homes and the trucks parked on them (playtest 2026-11-20).
func test_the_ways_are_drawn_under_every_marker() -> void:
	var least: MapMarker = autofree(MapMarker.new())
	least.importance = 9
	var roads: StarMapRoads = _roads()
	assert_lt(roads._material.render_priority, StarMapMarkers.rect_priority(least),
			"the lines under the least important rectangle, so under every pictogram too")
	var canyons := StarMapCanyons.new()
	add_child_autofree(canyons)
	assert_lt(canyons._material.render_priority, roads._strip_material.render_priority,
			"and the canyons still under the roads, strips included")


## No street, said twice, is no change -- whichever array says it. Told by identity alone, a body that
## is not loaded was handed a "new" empty set at every frame and its whole view was laid again each time.
func test_no_street_said_twice_is_no_change() -> void:
	var roads: StarMapRoads = _roads()
	roads.show_over({}, 10.0, STREET_RADIUS_M, [])
	var laid: Array = roads._village_roads_laid
	roads.show_over({}, 10.0, STREET_RADIUS_M, [])
	assert_true(is_same(roads._village_roads_laid, laid), "not taken for a new set of streets")
