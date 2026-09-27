extends GutTest

## The height sampler's C# half (TileFrameNative) against the GDScript it replaces, BIT FOR BIT.
##
## Heights feed the chunk meshes cached on disk, the server's collision and every prop placed on the
## ground: a sampler that moved the terrain by one ulp would invalidate all three, and client and server
## would disagree the day one of them ran without the assembly. So nothing here is "close enough" — each
## sample is compared with == against the GDScript path on a frame of its own.
##
## The C# half also has to actually answer: a twin that returned NaN everywhere would pass the equality
## and buy nothing, so the share of samples it served is asserted too.
##
## ⚠️ Equality rests on Math.Atan2 matching the engine's atan2 on the machine running this. Run it on a
## platform before trusting the C# path there.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_tile_frame_native.gd

const PlanetDataScript := preload("res://scenes/planet/planet_data.gd")
const NSIDE: int = 1024
const TILE_RES: int = 32
const BODY: String = "tarsis_3"


## A body whose pack is sparse and whose every climb is a pruning for good, not a tile yet to arrive:
## the case the C# half follows (Redirect). Nothing on disk exercises it offline — without the service's
## presence maps every climb counts as a guess — so it is staged.
class _SparseData extends PlanetData:
	func pack_is_sparse() -> bool:
		return true

	func _climb_is_guess(_nside: int, _ipix: int) -> bool:
		return false


func before_all() -> void:
	# Prints as it opens its packs; better outside any test.
	StarMapTiles.offline_data(BODY)


func after_each() -> void:
	PlanetData.TileFrame.use_native = true


## A frame with its C# half and one without, for the same body.
func _frames(pd: PlanetData, nside: int, ipix: int) -> Array:
	PlanetData.TileFrame.use_native = true
	var fast: PlanetData.TileFrame = pd.make_tile_frame()
	PlanetData.TileFrame.use_native = false
	var slow: PlanetData.TileFrame = pd.make_tile_frame()
	PlanetData.TileFrame.use_native = true
	pd.prepare_mountain_frame(fast, nside, ipix)
	pd.prepare_mountain_frame(slow, nside, ipix)
	return [fast, slow]


## Every direction of [param dirs] sampled through both frames; returns [differences, served by C#].
func _sample_both(pd: PlanetData, dirs: PackedVector3Array, ipix: int, nside: int, pitch: float,
		boundary: bool) -> Array:
	var frames: Array = _frames(pd, nside, ipix)
	var fast: PlanetData.TileFrame = frames[0]
	var slow: PlanetData.TileFrame = frames[1]
	var differ: int = 0
	var first_diff: String = ""
	for d: Vector3 in dirs:
		var a: float
		var b: float
		if boundary:
			a = pd.sample_height_boundary(d, ipix, -1, Vector2i(-1, -1), null, nside, fast, pitch)
			b = pd.sample_height_boundary(d, ipix, -1, Vector2i(-1, -1), null, nside, slow, pitch)
		else:
			a = pd.sample_height_for_direction(d, ipix, -1, Vector2i(-1, -1), null, nside, fast, pitch)
			b = pd.sample_height_for_direction(d, ipix, -1, Vector2i(-1, -1), null, nside, slow, pitch)
		if a != b:
			differ += 1
			if first_diff == "":
				first_diff = "%s: C# %.17g, GDScript %.17g" % [str(d), a, b]
	# Second pass, now that the GDScript has registered every tile: how much would the C# answer?
	var served: int = 0
	if fast.native != null:
		for d: Vector3 in dirs:
			var h: float
			if boundary:
				h = fast.native.SampleBoundary(d, ipix, nside, pitch)
			else:
				h = fast.native.Sample(d, ipix, nside, pitch)
			if not is_nan(h):
				served += 1
	return [differ, served, first_diff]


func _grid_dirs(nside: int, ipix: int, res: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for row: PackedVector3Array in HEALPix.get_pixel_grid(nside, ipix, res):
		out.append_array(row)
	return out


# ---------------------------------------------------------------------------

func test_the_assembly_is_there() -> void:
	assert_true(PlanetData.TileFrame.native_available(),
			"TileFrameNative.cs must load, or every test below measures the GDScript twice")


## Synthetic tiles: one tile and its eight neighbours, random texels, sampled over a grid finer than
## the tile — interior, edges and corners, where the kernel reaches into the neighbours.
func test_synthetic_tiles_sample_identically() -> void:
	var pd = PlanetDataScript.new()
	pd.planet_name = "native_test"
	pd.radius = 6356000.0
	pd.max_height = 10700.0
	pd.height_offset = -1700.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.chunk_heightmaps_dir = ""
	pd.export_nside = NSIDE
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	var ipix: int = NSIDE * NSIDE * 3 + 12345
	var seed_value: int = 1
	pd.store_chunk_image("hp_n%d_p%d" % [NSIDE, ipix], _random_tile(seed_value), [])
	var neighbours: Dictionary = HEALPix.get_neighbors_nest(NSIDE, ipix)
	for side: String in neighbours:
		seed_value += 1
		pd.store_chunk_image("hp_n%d_p%d" % [NSIDE, int(neighbours[side])], _random_tile(seed_value), [])
	var dirs: PackedVector3Array = _grid_dirs(NSIDE, ipix, 64)
	var interior: Array = _sample_both(pd, dirs, ipix, NSIDE, 25.0, false)
	assert_eq(interior[0], 0, "every sample equal: %s" % interior[2])
	assert_eq(interior[1], dirs.size(), "and the C# answered all of them")
	var rim: Array = _sample_both(pd, dirs, ipix, NSIDE, 25.0, true)
	assert_eq(rim[0], 0, "through sample_height_boundary too: %s" % rim[2])


## The real body: a sparse pack (most fine tiles pruned, read from an ancestor), streamed tiles, and
## procedural mountains — chunk-like grids at several levels under places that have them.
func test_the_real_ground_samples_identically() -> void:
	var pd: PlanetData = StarMapTiles.offline_data(BODY)
	if pd == null:
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	for label: String in ["Mining village 01", "Mining village 02", "Major railway city 08"]:
		var here: Vector3 = Vector3.ZERO
		for poi: Dictionary in StarMapPoi.load_for(BODY):
			if str(poi["label"]) == label:
				here = poi["dir"]
		for level: int in [16, 128, 1024]:
			var ipix: int = HEALPix.vec2pix_nest(level, here)
			var dirs: PackedVector3Array = _grid_dirs(level, ipix, 32)
			var pitch: float = pd.radius * HEALPix.pixel_angular_size(level) / 32.0
			var got: Array = _sample_both(pd, dirs, ipix, level, pitch, false)
			assert_eq(got[0], 0, "%s n%d: every sample equal: %s" % [label, level, got[2]])
			var rim: Array = _sample_both(pd, dirs, ipix, level, pitch, true)
			assert_eq(rim[0], 0, "%s n%d, rim: every sample equal: %s" % [label, level, rim[2]])
			# Where the tile is on disk the C# answers everything. Where it is not, the climb to an
			# ancestor is a GUESS offline — no presence map — and stays in GDScript on purpose.
			if not pd.load_chunk_floats(ipix, level).is_empty():
				assert_eq(int(got[1]), dirs.size(), "%s n%d: the C# answered every sample"
						% [label, level])


## A pruned tile read from its ancestor — the climb, followed by the C# once GDScript has settled it.
func test_a_pruned_tile_reads_its_ancestor_identically() -> void:
	var pd := _SparseData.new()
	pd.planet_name = "native_sparse"
	pd.radius = 6356000.0
	pd.max_height = 10700.0
	pd.height_offset = -1700.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.chunk_heightmaps_dir = ""
	pd.export_nside = NSIDE
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	# Only the PARENT level is stored, with its neighbours; the child asked for is pruned.
	var parent_nside: int = NSIDE / 2
	var parent: int = parent_nside * parent_nside * 5 + 777
	var seed_value: int = 100
	pd.store_chunk_image("hp_n%d_p%d" % [parent_nside, parent], _random_tile(seed_value), [])
	var neighbours: Dictionary = HEALPix.get_neighbors_nest(parent_nside, parent)
	for side: String in neighbours:
		seed_value += 1
		pd.store_chunk_image("hp_n%d_p%d" % [parent_nside, int(neighbours[side])],
				_random_tile(seed_value), [])
	var child: int = parent * 4 + 2
	var dirs: PackedVector3Array = _grid_dirs(NSIDE, child, 32)
	var got: Array = _sample_both(pd, dirs, child, NSIDE, 25.0, false)
	assert_eq(got[0], 0, "every sample equal: %s" % got[2])
	assert_eq(int(got[1]), dirs.size(), "and the C# followed the climb for all of them")


## Directions all over the sphere — every face, both poles — with the tile left for the sampler to
## find (known_export_ipix = -1), so the C# vec2pix is exercised against the GDScript one.
func test_directions_everywhere_sample_identically() -> void:
	var pd: PlanetData = StarMapTiles.offline_data(BODY)
	if pd == null:
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260927
	var dirs := PackedVector3Array([Vector3.UP, Vector3.DOWN, Vector3(1, 0, 0), Vector3(0, 0, -1)])
	for i: int in range(3000):
		dirs.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
				.normalized())
	for level: int in [4, 64]:
		PlanetData.TileFrame.use_native = true
		var fast: PlanetData.TileFrame = pd.make_tile_frame()
		PlanetData.TileFrame.use_native = false
		var slow: PlanetData.TileFrame = pd.make_tile_frame()
		PlanetData.TileFrame.use_native = true
		var differ: int = 0
		var first_diff: String = ""
		for d: Vector3 in dirs:
			# A frame per body, not per tile: the mountains of one tile would be wrong elsewhere, so
			# this runs with none prepared — what a gameplay query with a frame would do.
			var a: float = pd._base_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, level, slow)
			var b: float = a
			if fast.native != null:
				pd._base_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, level, fast)
				var c: float = fast.native.Sample(d, -1, level, 0.0)
				if not is_nan(c):
					b = c
			if a != b:
				differ += 1
				if first_diff == "":
					first_diff = "%s: C# %.17g, GDScript %.17g" % [str(d), b, a]
		assert_eq(differ, 0, "n%d, over the whole sphere: %s" % [level, first_diff])


func _random_tile(seed_value: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for y: int in range(TILE_RES):
		for x: int in range(TILE_RES):
			img.set_pixel(x, y, Color(rng.randf(), 0.0, 0.0))
	return img
