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
				h = fast.native.SampleBoundary(d, ipix, nside, pitch, CrackCarve.AUTO)
			else:
				h = fast.native.Sample(d, ipix, nside, pitch, CrackCarve.AUTO)
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
				var c: float = fast.native.Sample(d, -1, level, 0.0, CrackCarve.NONE)
				if not is_nan(c):
					b = c
			if a != b:
				differ += 1
				if first_diff == "":
					first_diff = "%s: C# %.17g, GDScript %.17g" % [str(d), b, a]
		assert_eq(differ, 0, "n%d, over the whole sphere: %s" % [level, first_diff])


## The whole sphere with NO data on disk — what a CI machine has. Random tiles are made under 300
## directions (every face, both poles, the face seams) and their neighbours, and the C# half has to find
## the tile itself (known_export_ipix = -1): its vec2pix and its face coordinates, i.e. Math.Atan2,
## against the engine's atan2. The tarsis_3 tests above go pending without a tile cache; this one never
## does, so it is the one that proves a platform.
func test_the_whole_sphere_samples_identically_without_data() -> void:
	var setup: Array = _whole_sphere()
	var pd = setup[0]
	var dirs: PackedVector3Array = setup[1]
	var frames: Array = _frames(pd, 64, -1)
	var fast: PlanetData.TileFrame = frames[0]
	var slow: PlanetData.TileFrame = frames[1]
	for d: Vector3 in dirs:  # the GDScript registers every tile the C# will need
		pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64, fast, 0.0)
	var differ: int = 0
	var served: int = 0
	var first: String = ""
	for d: Vector3 in dirs:
		var b: float = pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64, slow, 0.0)
		var c: float = fast.native.Sample(d, -1, 64, 0.0, CrackCarve.AUTO) if fast.native != null else NAN
		if not is_nan(c):
			served += 1
			if c != b:
				differ += 1
				if first == "":
					first = "%s: C# %s, GDScript %s" % [str(d), String.num(c, 14), String.num(b, 14)]
	assert_eq(differ, 0, "every direction equal: %s" % first)
	assert_eq(served, dirs.size(), "and the C# answered every one")


## The corundum cracks carved by the sampler (CrackCarve), C# against GDScript: AUTO (the zone rule,
## answered by the frame over a tile with no zone) and CARVE (a chunk's normal probes), at full detail and
## at a chunk's pitch, on chunks a POI sphere half covers — its ramp is the crack factor. Both paths reach
## the Voronoi through CrackVoronoiNative, the same on every machine (see test_crack_voronoi_native.gd
## for the Voronoi itself against the Linux reference). Non-vacuous: the carve is asserted to be there.
## Bit for bit where the engine and .NET share the libm (Linux); elsewhere within a micrometre, as the
## reference heights below: over these 57 624 samples Windows' Math.Atan2 sits an ulp off the engine's
## atan2 in the BASE sampler at two uncarved ones (7.7e-9 m, CI run 36599103278).
func test_the_cracks_sample_identically() -> void:
	var setup: Array = _whole_sphere()
	var pd = setup[0]
	var dirs: PackedVector3Array = setup[1]
	pd.corundum_default_biome = true
	pd.crack_spacing_m = 4000.0
	pd.crack_width_m = 250.0
	pd.crack_depth_m = 180.0
	pd.crack_poi_margin_m = 300.0
	var chunks: Array = []
	var pois: Array = []
	for i: int in range(24):
		var ipix: int = HEALPix.vec2pix_nest(1024, dirs[i])
		chunks.append(ipix)
		if i % 2 == 0:  # a POI on every other chunk, 1.2 km off its centre
			var c: Vector3 = HEALPix.pix2vec_nest(1024, ipix)
			pois.append({"dir": (c + c.cross(Vector3.UP).normalized() * (1200.0 / pd.radius)).normalized(),
					"radius": 1000.0})
	pd.set_crack_exclusions(pois)
	for mode: int in [CrackCarve.AUTO, CrackCarve.CARVE]:
		for pitch: float in [0.0, 25.0]:
			var differ: int = 0
			var served: int = 0
			var carved: int = 0
			var ramped: int = 0
			var worst: float = 0.0
			var first: String = ""
			for ipix: int in chunks:
				var frames: Array = _frames(pd, 1024, ipix)
				var fast: PlanetData.TileFrame = frames[0]
				var slow: PlanetData.TileFrame = frames[1]
				CrackCarve.prepare_frame(pd, fast, 1024, ipix)
				CrackCarve.prepare_frame(pd, slow, 1024, ipix)
				var grid: PackedVector3Array = _grid_dirs(1024, ipix, 48)
				for d: Vector3 in grid:  # the GDScript registers every tile the C# will need
					pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64, fast, pitch, mode)
				for d: Vector3 in grid:
					var b: float = pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64, slow,
							pitch, mode)
					var bare: float = pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64,
							slow, pitch, CrackCarve.NONE)
					if b != bare:
						carved += 1
						var w: float = pd.crack_factor(d, slow.crack_pois, slow)
						if w > 0.0 and w < 1.0:
							ramped += 1
					var c: float = fast.native.Sample(d, -1, 64, pitch, mode) if fast.native != null else NAN
					if not is_nan(c):
						served += 1
						if c != b:
							differ += 1
							if absf(c - b) > worst:
								worst = absf(c - b)
								first = "%s: C# %s, GDScript %s" % [str(d), String.num(c, 14), String.num(b, 14)]
			var label: String = "mode %d, pitch %.0f" % [mode, pitch]
			if OS.get_name() == "Linux":
				assert_eq(differ, 0, "%s: every sample equal: %s" % [label, first])
			else:
				assert_lte(worst, 1.0e-6, "%s: %d samples off, within a micrometre: %s" % [label, differ, first])
			# A rim sample in a crack of the NEXT export tile is left to GDScript under AUTO (the frame
			# holds the zone rule of its own tile only); everything else is the C#'s.
			assert_gt(served, int(chunks.size() * 49 * 49 * 0.97), "%s: the C# answered (%d)" % [label, served])
			assert_gt(carved, 500, "%s: the samples do fall in cracks (%d)" % [label, carved])
			assert_gt(ramped, 10, "%s: and in a POI's ramp (%d)" % [label, ramped])
	# At a pitch past half the crack width nothing is carved, in either path.
	var ipix0: int = chunks[0]
	var coarse: PlanetData.TileFrame = _frames(pd, 1024, ipix0)[0]
	CrackCarve.prepare_frame(pd, coarse, 1024, ipix0)
	for d: Vector3 in _grid_dirs(1024, ipix0, 16):
		assert_eq(pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64, coarse, 130.0),
				pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64, coarse, 130.0,
						CrackCarve.NONE), "no crack at a 130 m pitch")


## The same heights against a reference machine's, frozen in fixtures/tile_frame_linux.b64 (Fedora,
## glibc 2.43). Equal to the local GDScript is not enough across machines: a Windows client and the
## Linux server have to stand on the same ground, and libms differ in their last bits (the crack
## Voronoi's sine does; see test_crack_voronoi_native.gd). The sampler uses no sine — atan2 and sqrt —
## and measured it is bit-identical on GitHub's Ubuntu and on Windows; held to a micrometre so that a
## libm's ulp somewhere else does not fail it. Regenerate on purpose only.
func test_the_whole_sphere_gives_the_reference_heights() -> void:
	var want: PackedFloat64Array = _linux_heights()
	assert_gt(want.size(), 0, "the reference file is there")
	var setup: Array = _whole_sphere()
	var pd = setup[0]
	var dirs: PackedVector3Array = setup[1]
	var fast: PlanetData.TileFrame = _frames(pd, 64, -1)[0]
	for d: Vector3 in dirs:
		pd.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, 64, fast, 0.0)
	var worst: float = 0.0
	var first: String = ""
	for i: int in range(mini(dirs.size(), want.size())):
		var c: float = pd.sample_height_for_direction(dirs[i], -1, -1, Vector2i(-1, -1), null, 64, fast, 0.0)
		if absf(c - want[i]) > worst:
			worst = absf(c - want[i])
			first = "%s: here %s, reference %s" % [str(dirs[i]), String.num(c, 14), String.num(want[i], 14)]
	assert_lte(worst, 1.0e-6, "the C# sampler within a micrometre of the reference: %s" % first)


const LINUX_HEIGHTS: String = "res://test/unit/fixtures/tile_frame_linux.b64"


func _linux_heights() -> PackedFloat64Array:
	var f := FileAccess.open(LINUX_HEIGHTS, FileAccess.READ)
	if f == null:
		return PackedFloat64Array()
	var raw: PackedByteArray = Marshalls.base64_to_raw(f.get_as_text().strip_edges())
	f.close()
	return raw.to_float64_array()


## A body with random tiles under 300 directions — every face, both poles, the face seams — and their
## neighbours. Deterministic on every machine: an integer RNG and IEEE arithmetic only.
func _whole_sphere() -> Array:
	var pd = PlanetDataScript.new()
	pd.planet_name = "native_sphere"
	pd.radius = 6356000.0
	pd.max_height = 10700.0
	pd.height_offset = -1700.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.chunk_heightmaps_dir = ""
	pd.export_nside = 64
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 314159
	var dirs := PackedVector3Array([Vector3.UP, Vector3.DOWN, Vector3(1, 0, 0), Vector3(-1, 0, 0),
			Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 1, 0).normalized(), Vector3(0, 1, 1).normalized(),
			Vector3(0.0, 2.0 / 3.0, sqrt(1.0 - 4.0 / 9.0))])
	while dirs.size() < 300:
		dirs.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
				.normalized())
	# Mirrored in z since longitude became atan2(-z, x): each direction lands on the pixel and the face
	# coordinates it had when tile_frame_linux.b64 was frozen, so the reference still holds bit for bit.
	for i: int in range(dirs.size()):
		dirs[i] = Vector3(dirs[i].x, dirs[i].y, -dirs[i].z)
	var stored: Dictionary = {}
	for d: Vector3 in dirs:
		var ipix: int = HEALPix.vec2pix_nest(64, d)
		var around: Array = [ipix]
		around.append_array(HEALPix.get_neighbors_nest(64, ipix).values())
		for tile: Variant in around:
			if int(tile) >= 0 and not stored.has(int(tile)):
				stored[int(tile)] = true
				pd.store_chunk_image("hp_n64_p%d" % int(tile), _fast_random_tile(rng), [])
	return [pd, dirs]


func _fast_random_tile(rng: RandomNumberGenerator) -> Image:
	var texels := PackedFloat32Array()
	texels.resize(TILE_RES * TILE_RES)
	for i: int in range(texels.size()):
		texels[i] = rng.randf()
	return Image.create_from_data(TILE_RES, TILE_RES, false, Image.FORMAT_RF, texels.to_byte_array())


func _random_tile(seed_value: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for y: int in range(TILE_RES):
		for x: int in range(TILE_RES):
			img.set_pixel(x, y, Color(rng.randf(), 0.0, 0.0))
	return img
