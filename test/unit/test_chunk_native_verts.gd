extends GutTest
## The vertex loop in C# (TileFrameNative.Verts.cs) against the GDScript loop it replaces, on whole meshes,
## BIT FOR BIT, and on what it must leave to that loop.
##
## Everything a chunk is built from starts here: positions, UVs, the crack flags, the colours' inputs. On
## Linux nothing is "close enough". And a loop that served no vertex would pass every equality, so the share
## it served is asserted too, on the fixtures where it must serve them all.
##
## Synthetic planet for what must run everywhere, tarsis_3 for the real thing (pending without its tiles).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_chunk_native_verts.gd -gexit

const BODY := "tarsis_3"
const TILE_RES := 16
const EXPORT_NSIDE := 8
const DEPTH := 6
const CHUNK_NSIDE := 64
const RES := 32
const VERT_COUNT := (RES + 1) * (RES + 1)
const RADIUS := 1000000.0
const RELIEF_BIOME := "test-relief"
const CLIFF_BIOME := RockyLandformCliffTerrain.BIOME_TYPE
## Off Linux the engine's sin and atan2 differ a little from .NET's: what a vertex attribute can show.
const CROSS_MACHINE := 1.0e-3


class _SparseData extends PlanetData:
	var guess := false

	func pack_is_sparse() -> bool:
		return true

	func _climb_is_guess(_nside: int, _ipix: int) -> bool:
		return guess


var _pd: PlanetData = null
var _export_ipix := -1
var _hp_ipix := -1
var _centre := Vector2.ZERO


func before_all() -> void:
	RockCatalogue.reload()
	RockImpurity.reset()
	RockImpurity.warm()
	@warning_ignore("integer_division")
	var x := EXPORT_NSIDE / 2
	@warning_ignore("integer_division")
	var y := EXPORT_NSIDE / 2 + 1
	_export_ipix = 4 * EXPORT_NSIDE * EXPORT_NSIDE + HEALPix.xy2nest(x, y)
	_hp_ipix = _export_ipix
	var ns := EXPORT_NSIDE
	while ns < CHUNK_NSIDE:
		_hp_ipix = (_hp_ipix << 2) | 3
		ns *= 2
	_centre = HEALPix.vec2lonlat(HEALPix.pix2vec_nest(CHUNK_NSIDE, _hp_ipix))
	_pd = _planet(PlanetData.new())


func after_each() -> void:
	PlanetChunk.use_native_verts = true


func _planet(pd: PlanetData, corundum: bool = true, skip_tile: int = -1) -> PlanetData:
	pd.planet_name = "native_verts"
	pd.radius = RADIUS
	pd.max_height = 500.0
	pd.height_offset = 0.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.chunk_resolution = RES
	pd.max_quadtree_depth = DEPTH
	pd.export_nside = EXPORT_NSIDE
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	pd.chunk_heightmaps_dir = ""
	pd.corundum_default_biome = corundum
	pd.corundum_default_rock = "corundum_red"
	pd.crack_spacing_m = 12000.0
	pd.crack_width_m = 1500.0
	pd.crack_depth_m = 150.0
	var plateau := BiomeDefinition.new()
	plateau.biome_type = ArideDesertCorundumPlateauTerrain.BIOME_TYPE
	plateau.color = Color(0.7, 0.3, 0.3)
	var relief := BiomeDefinition.new()
	relief.biome_type = RELIEF_BIOME
	relief.color = Color(0.3, 0.4, 0.7)
	relief.relief_min_m = -12.0
	relief.relief_max_m = 12.0
	relief.relief_wavelength_m = 4000.0
	var cliff := BiomeDefinition.new()
	cliff.biome_type = CLIFF_BIOME
	cliff.color = Color(0.5, 0.5, 0.4)
	pd.biome_definitions = [plateau, relief, cliff]
	var ns := 1
	while ns <= EXPORT_NSIDE:
		for ipix in 12 * ns * ns:
			if not (ns == EXPORT_NSIDE and ipix == skip_tile):
				pd.store_chunk_image("hp_n%d_p%d" % [ns, ipix], _tile(ipix), [])
		ns *= 2
	# A relief biome of another corundum over the west half, a massif over the east half.
	_zones(pd, [_zone(RELIEF_BIOME, "corundum_blue", -2.0, 0.0)])
	pd.set_mountain_overrides([{"coverage": "partial", "amplitude_m": 400.0, "wavelength_m": 8000.0, "octaves": 5,
			"feather_m": 2000.0, "seed": 11, "polygon": PackedVector2Array([_centre + Vector2(0.0, -2.0),
			_centre + Vector2(3.0, -2.0), _centre + Vector2(3.0, 2.0), _centre + Vector2(0.0, 2.0)])}], [])
	pd.warm_mountains()
	return pd


func _zone(biome: String, rock: String, west: float, east: float) -> Dictionary:
	var zone := {"coverage": "polygon", "biome_type": biome,
			"vertices": [[_centre.x + west, _centre.y - 2.0], [_centre.x + east, _centre.y - 2.0],
			[_centre.x + east, _centre.y + 2.0], [_centre.x + west, _centre.y + 2.0]]}
	if not rock.is_empty():
		zone["rock_type"] = rock
	return zone


func _zones(pd: PlanetData, zones: Array) -> void:
	pd._chunk_populate_zones["hp_n%d_p%d" % [EXPORT_NSIDE, _export_ipix]] = zones


func _tile(ipix: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	for y in TILE_RES:
		for x in TILE_RES:
			img.set_pixel(x, y, Color(0.5 + 0.2 * sin(x * 0.7 + ipix) * cos(y * 0.5), 0.0, 0.0))
	return img


func _build(pd: PlanetData, nside: int, ipix: int, res: int, native: bool, stitch: int = 0) -> Dictionary:
	PlanetChunk.use_native_verts = native
	var prof := {}
	var centre := HEALPix.pix2vec_nest(nside, ipix) * pd.radius
	var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(pd, nside, ipix, res, centre, prof, stitch)
	PlanetChunk.use_native_verts = true
	return {"mesh": mesh, "served": int(prof.get("verts_served", 0))}


func _same(a: Variant, b: Variant, key: int) -> bool:
	if a == b:
		return true
	if OS.get_name() == "Linux" or typeof(a) != typeof(b) or key == Mesh.ARRAY_INDEX or a == null or b == null:
		return false
	if a.size() != b.size():
		return false
	for i: int in a.size():
		var x: Variant = a[i]
		var y: Variant = b[i]
		var gap := 0.0
		if x is Color:
			gap = maxf(maxf(absf(x.r - y.r), absf(x.g - y.g)), absf(x.b - y.b))
		elif x is Vector3 or x is Vector2:
			gap = (x - y).length()
		else:
			gap = absf(float(x) - float(y))
		if gap > CROSS_MACHINE:
			return false
	return true


## Every array of every surface of the two meshes.
func _assert_identical(fast: Dictionary, slow: Dictionary, label: String) -> void:
	var a: ArrayMesh = fast["mesh"]
	var b: ArrayMesh = slow["mesh"]
	assert_true(a != null and b != null, "%s: meshes came out" % label)
	if a == null or b == null:
		return
	assert_gt(b.get_surface_count(), 0, "%s: with a surface" % label)
	assert_eq(a.get_surface_count(), b.get_surface_count(), "%s: as many surfaces" % label)
	for s: int in mini(a.get_surface_count(), b.get_surface_count()):
		var fa: Array = a.surface_get_arrays(s)
		var fb: Array = b.surface_get_arrays(s)
		for k: int in Mesh.ARRAY_MAX:
			if not _same(fa[k], fb[k], k):
				assert_true(false, "%s: surface %d, array %d differs" % [label, s, k])
				return
	pass_test(label)


func test_the_assembly_is_there() -> void:
	assert_true(PlanetData.TileFrame.native_available(), "TileFrameNative.cs must load, with the vertex loop")


## Mountains, cracks, a relief biome and two rocks, on the finest grid, a coarser one and a chunk on a tile
## seam. The C# serves every vertex: it asks for the tiles it misses and carries on.
func test_synthetic_chunks_are_identical_and_all_served() -> void:
	for chunk: Array in [[CHUNK_NSIDE, _hp_ipix], [CHUNK_NSIDE, _hp_ipix - 1], [CHUNK_NSIDE / 2, _hp_ipix >> 2]]:
		var slow := _build(_pd, chunk[0], chunk[1], RES, false)
		var fast := _build(_pd, chunk[0], chunk[1], RES, true)
		_assert_identical(fast, slow, "n%d p%d" % [chunk[0], chunk[1]])
		assert_eq(int(slow["served"]), 0, "the switch of the tests is honoured")
		assert_eq(int(fast["served"]), VERT_COUNT, "n%d p%d: the C# served every vertex" % [chunk[0], chunk[1]])


## Not vacuous: this chunk's vertices do reach the cracks, the relief, the massif and both rocks.
func test_the_fixture_reaches_every_term() -> void:
	var arrays: Array = (_build(_pd, CHUNK_NSIDE, _hp_ipix, RES, true)["mesh"] as ArrayMesh).surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var distinct := {}
	for c: Color in colors:
		distinct[c] = true
	assert_gt(distinct.size(), colors.size() / 4, "shades all over the chunk")
	var frame: PlanetData.TileFrame = _pd.make_tile_frame()
	_pd.prepare_mountain_frame(frame, CHUNK_NSIDE, _hp_ipix)
	CrackCarve.prepare_frame(_pd, frame, CHUNK_NSIDE, _hp_ipix)
	var pitch := HEALPix.pixel_side_length(CHUNK_NSIDE, RADIUS) / float(RES)
	var carved := 0
	var core := 0.0
	for row: PackedVector3Array in HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES):
		for d: Vector3 in row:
			core = maxf(core, _pd.mountain_core(d, frame))
			if _pd.crack_factor(d, frame.crack_pois, frame) > 0.0 \
					and ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(d, RADIUS, _pd.crack_spacing_m,
					_pd.crack_width_m, pitch, _pd.crack_noise()) < _pd.crack_width_m * 0.5:
				carved += 1
	assert_gt(carved, 0, "the crack network crosses the chunk")
	assert_gt(core, 0.0, "the massif is under the chunk")
	assert_true(BiomeRelief.visible_at(_pd.get_biome_by_type(RELIEF_BIOME), pitch), "the relief shows at this pitch")


## The LOD stitch: forced border heights, blended rows, on a level it applies to.
func test_a_stitched_chunk_is_identical() -> void:
	var nside := EXPORT_NSIDE * 2
	var ipix := _hp_ipix >> (2 * 2)
	assert_true(PlanetChunk.edge_stitch_applies(_pd, nside), "this level stitches")
	var moved := false
	var plain: Array = (_build(_pd, nside, ipix, RES, false)["mesh"] as ArrayMesh).surface_get_arrays(0)
	for stitch: int in [1, 2, 4, 8, 15]:
		var slow := _build(_pd, nside, ipix, RES, false, stitch)
		var fast := _build(_pd, nside, ipix, RES, true, stitch)
		_assert_identical(fast, slow, "stitch %d" % stitch)
		assert_gt(int(fast["served"]), 0, "stitch %d: the C# did serve" % stitch)
		moved = moved or (slow["mesh"] as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] != plain[Mesh.ARRAY_VERTEX]
	assert_true(moved, "the masks do move the border")


## A zone whose rule stays in GDScript (a cliff's drop): only its vertices go back, and the mesh does not move.
func test_a_special_zone_stays_gdscript_and_the_rest_is_served() -> void:
	var pd := _planet(PlanetData.new())
	_zones(pd, [_zone(CLIFF_BIOME, "", -2.0, 0.0)])
	var slow := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, false)
	var fast := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, true)
	_assert_identical(fast, slow, "cliff zone")
	assert_gt(int(fast["served"]), 0, "the east half is the C#'s")
	assert_lt(int(fast["served"]), VERT_COUNT, "the west half is GDScript's")


## What reaches every vertex (here a canyon) keeps the whole chunk in GDScript.
func test_a_linear_feature_keeps_the_chunk_in_gdscript() -> void:
	var pd := _planet(PlanetData.new())
	var line := PackedVector2Array([_centre + Vector2(-1.0, -0.1), _centre + Vector2(1.0, 0.1)])
	var feature := {"type": "rocky_landform-canyon", "centerline": line, "width": 800.0, "width_start_m": 800.0,
			"width_end_m": 800.0}
	PlanetChunk.prepare_linear_zone(feature, RADIUS)
	pd._chunk_linear_features["hp_n%d_p%d" % [EXPORT_NSIDE, _export_ipix]] = [feature]
	var slow := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, false)
	var fast := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, true)
	_assert_identical(fast, slow, "canyon")
	assert_eq(int(fast["served"]), 0, "the C# stays out")


## Pads are GDScript's: a vertex within reach goes back, the others do not, and neither path moves the mesh.
func test_a_pad_stays_gdscript_within_its_reach() -> void:
	var pd := _planet(PlanetData.new())
	pd.register_pad(PadBed.record("prop:test", _centre.x - 0.4, _centre.y, 0.3, 200.0, 150.0, 8.0, 0.0))
	assert_true(pd.has_pads(), "the fixture has its pad")
	var slow := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, false)
	var fast := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, true)
	_assert_identical(fast, slow, "pad")
	assert_gt(int(fast["served"]), 0, "away from the pad: the C#'s")
	assert_lt(int(fast["served"]), VERT_COUNT, "around the pad: GDScript's")


## A pruned tile read from its ancestor: the climb, settled once by GDScript and then followed by the C#.
func test_a_pruned_tile_is_identical_and_served() -> void:
	var pd: _SparseData = _planet(_SparseData.new(), true, _export_ipix)
	var slow := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, false)
	var fast := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, true)
	_assert_identical(fast, slow, "pruned tile")
	assert_gt(int(fast["served"]), VERT_COUNT / 2, "the C# follows the climb")


## A climb that is only a guess stays in GDScript, and the mesh is still marked provisional, on both paths.
func test_a_guessed_climb_stays_provisional() -> void:
	var pd: _SparseData = _planet(_SparseData.new(), true, _export_ipix)
	pd.guess = true
	var slow := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, false)
	var fast := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, true)
	_assert_identical(fast, slow, "guessed climb")
	assert_gt(int((slow["mesh"] as ArrayMesh).get_meta("provisional_climbs")), 0, "GDScript marks it provisional")
	assert_gt(int((fast["mesh"] as ArrayMesh).get_meta("provisional_climbs")), 0, "and so does the C# path")


## A planet without the corundum default (the moons): the colour of a vertex in no zone comes from
## sample_biome_at, per direction, set by GDScript over a pass the C# still does.
func test_a_planet_without_corundum_is_identical_and_served() -> void:
	var pd := _planet(PlanetData.new(), false)
	_zones(pd, [])
	var slow := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, false)
	var fast := _build(pd, CHUNK_NSIDE, _hp_ipix, RES, true)
	_assert_identical(fast, slow, "no corundum")
	assert_eq(int(fast["served"]), VERT_COUNT, "the C# serves all but the colour")


## tarsis_3's towns and open ground, with and without stitch, on the levels the game streams.
func test_real_chunks_are_identical() -> void:
	var pd: PlanetData = StarMapTiles.offline_data(BODY)
	if pd == null:
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	pd.warm_biome_cache()
	var built := 0
	var served := 0
	for poi: Dictionary in StarMapPoi.load_for(BODY):
		var d: Vector3 = poi["dir"]
		if pd.load_chunk_floats(HEALPix.vec2pix_nest(pd.export_nside, d), pd.export_nside).is_empty():
			continue
		for nside: int in [1024, 2048, 4096, 8192]:
			var ipix: int = HEALPix.vec2pix_nest(nside, d)
			for stitch: int in [0, 15]:
				var slow := _build(pd, nside, ipix, pd.chunk_resolution, false, stitch)
				var fast := _build(pd, nside, ipix, pd.chunk_resolution, true, stitch)
				_assert_identical(fast, slow, "%s n%d stitch %d" % [str(poi["label"]), nside, stitch])
				served += int(fast["served"])
			built += 2
		if built >= 16:
			break
	if built == 0:
		pending("aucune tuile de lieu %s sur cette machine" % BODY)
		return
	assert_gt(served, 0, "the C# served real vertices")
