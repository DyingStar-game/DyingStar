extends GutTest
## The chunk passes in C# (TileFrameNative.Normals, RockImpurityNative) against the GDScript loops they
## replace, on whole meshes, BIT FOR BIT.
##
## Normals and colours are cached on disk and every client must agree on them, so on Linux nothing here is
## "close enough". The other half of the contract is that the C# really answers: an equality with a pass
## that declined every vertex would prove nothing, so the share it served is asserted too.
##
## Synthetic planet for what must run everywhere, tarsis_3 for the real thing (pending without its tiles).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_chunk_native_normals.gd -gexit

const BODY := "tarsis_3"
const TILE_RES := 16
const EXPORT_NSIDE := 8
const DEPTH := 6
const CHUNK_NSIDE := 64
const RES := 32
const RADIUS := 1000000.0
const RELIEF_BIOME := "test-relief"
## Off Linux the engine's sin and atan2 differ a little from .NET's: what a normal or a colour can show.
const CROSS_MACHINE := 1.0e-3

var _pd: PlanetData = null
var _export_ipix := -1
var _hp_ipix := -1


func before_all() -> void:
	RockCatalogue.reload()
	RockImpurity.reset()
	RockImpurity.warm()
	_pd = _planet()
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
	var c := HEALPix.vec2lonlat(HEALPix.pix2vec_nest(CHUNK_NSIDE, _hp_ipix))
	# A relief biome of another corundum over the west half, its colour and its cracks with it.
	_pd._chunk_populate_zones["hp_n%d_p%d" % [EXPORT_NSIDE, _export_ipix]] = [{
		"coverage": "polygon", "biome_type": RELIEF_BIOME, "rock_type": "corundum_blue",
		"vertices": [[c.x - 2.0, c.y - 2.0], [c.x, c.y - 2.0], [c.x, c.y + 2.0], [c.x - 2.0, c.y + 2.0]],
	}]
	_pd.set_mountain_overrides([_mountain(c)], [])
	_pd.warm_mountains()


func after_each() -> void:
	PlanetChunk.use_native_normals = true
	RockImpurity.use_native = true


func _planet() -> PlanetData:
	var pd := PlanetData.new()
	pd.planet_name = "native_normals"
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
	pd.corundum_default_biome = true
	pd.corundum_default_rock = "corundum_red"
	pd.crack_spacing_m = 12000.0
	pd.crack_width_m = 1500.0
	pd.crack_depth_m = 150.0
	var plateau := BiomeDefinition.new()
	plateau.biome_type = ArideDesertCorundumPlateauTerrain.BIOME_TYPE
	var relief := BiomeDefinition.new()
	relief.biome_type = RELIEF_BIOME
	relief.relief_min_m = -12.0
	relief.relief_max_m = 12.0
	relief.relief_wavelength_m = 4000.0
	pd.biome_definitions = [plateau, relief]
	var ns := 1
	while ns <= EXPORT_NSIDE:
		for ipix in 12 * ns * ns:
			pd.store_chunk_image("hp_n%d_p%d" % [ns, ipix], _tile(ipix), [])
		ns *= 2
	return pd


func _tile(ipix: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	for y in TILE_RES:
		for x in TILE_RES:
			img.set_pixel(x, y, Color(0.5 + 0.2 * sin(x * 0.7 + ipix) * cos(y * 0.5), 0.0, 0.0))
	return img


## A massif over the chunk's east half (MountainRelief's pack-decoded record): the network fades out under
## it, so the west half keeps the cracks.
func _mountain(c: Vector2) -> Dictionary:
	return {"coverage": "partial", "amplitude_m": 400.0, "wavelength_m": 8000.0, "octaves": 5, "feather_m": 2000.0,
			"seed": 11, "polygon": PackedVector2Array([c + Vector2(0.0, -2.0), c + Vector2(3.0, -2.0),
			c + Vector2(3.0, 2.0), c + Vector2(0.0, 2.0)])}


## The arrays of a chunk's base surface, built with the C# passes on or off.
func _mesh_arrays(pd: PlanetData, nside: int, ipix: int, res: int, native: bool) -> Array:
	PlanetChunk.use_native_normals = native
	RockImpurity.use_native = native
	var centre := HEALPix.pix2vec_nest(nside, ipix) * pd.radius
	var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(pd, nside, ipix, res, centre)
	PlanetChunk.use_native_normals = true
	RockImpurity.use_native = true
	return mesh.surface_get_arrays(0) if mesh != null and mesh.get_surface_count() > 0 else []


## [vertices compared, normals off, colours off, worst normal gap, worst colour gap, anything else off]
func _compare_arrays(fast: Array, slow: Array) -> Dictionary:
	var out := {"n": 0, "normals": 0, "colors": 0, "worst_normal": 0.0, "worst_color": 0.0, "other": 0}
	if fast.is_empty() or slow.is_empty():
		return out
	var nf: PackedVector3Array = fast[Mesh.ARRAY_NORMAL]
	var ns: PackedVector3Array = slow[Mesh.ARRAY_NORMAL]
	var cf: PackedColorArray = fast[Mesh.ARRAY_COLOR]
	var cs: PackedColorArray = slow[Mesh.ARRAY_COLOR]
	out["n"] = nf.size()
	if nf.size() != ns.size() or cf.size() != cs.size():
		out["other"] = 1
		return out
	for i: int in nf.size():
		if nf[i] != ns[i]:
			out["normals"] += 1
			out["worst_normal"] = maxf(out["worst_normal"], (nf[i] - ns[i]).length())
		if cf[i] != cs[i]:
			out["colors"] += 1
			out["worst_color"] = maxf(out["worst_color"], maxf(absf(cf[i].r - cs[i].r),
					maxf(absf(cf[i].g - cs[i].g), absf(cf[i].b - cs[i].b))))
	# The positions, UVs, tangents and indices follow from the same inputs: they must not move either.
	for k: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]:
		if fast[k] != slow[k]:
			out["other"] += 1
	return out


func _assert_equal(cmp: Dictionary, label: String) -> void:
	assert_gt(int(cmp["n"]), 0, "%s: a mesh came out" % label)
	assert_eq(int(cmp["other"]), 0, "%s: positions, UVs and indices equal" % label)
	if OS.get_name() == "Linux":
		assert_eq(int(cmp["normals"]), 0, "%s: every normal equal (worst %s)" % [label, str(cmp["worst_normal"])])
		assert_eq(int(cmp["colors"]), 0, "%s: every colour equal (worst %s)" % [label, str(cmp["worst_color"])])
	else:
		assert_lte(float(cmp["worst_normal"]), CROSS_MACHINE, "%s: normals within the bound" % label)
		assert_lte(float(cmp["worst_color"]), CROSS_MACHINE, "%s: colours within the bound" % label)


func _frame(pd: PlanetData, nside: int, ipix: int) -> PlanetData.TileFrame:
	var frame: PlanetData.TileFrame = pd.make_tile_frame()
	pd.prepare_mountain_frame(frame, nside, ipix)
	CrackCarve.prepare_frame(pd, frame, nside, ipix)
	return frame


## The chunk's grid as generate_mesh's arrays hold it, every tile it reads registered through the GDScript.
func _grid(pd: PlanetData, frame: PlanetData.TileFrame, nside: int, ipix: int, pitch: float) -> PackedVector3Array:
	var dirs := PackedVector3Array()
	for row: PackedVector3Array in HEALPix.get_pixel_grid(nside, ipix, RES):
		dirs.append_array(row)
	for d: Vector3 in dirs:
		pd.sample_height_boundary(d, _export_ipix, -1, Vector2i(-1, -1), null, EXPORT_NSIDE, frame, pitch, CrackCarve.NONE)
	return dirs


func _normals_of(frame: PlanetData.TileFrame, dirs: PackedVector3Array, pitch: float) -> PackedVector3Array:
	var edge := PackedFloat32Array()
	edge.resize(dirs.size())
	var snapped := PackedByteArray()
	snapped.resize(dirs.size())
	var eps := HEALPix.pixel_side_length(CHUNK_NSIDE, 1.0) * (0.25 / float(RES))
	return frame.native.Normals(dirs, edge, snapped, RES, _export_ipix, EXPORT_NSIDE, pitch, eps, 0.0, false, eps, 0.0)


func test_the_assembly_is_there() -> void:
	assert_true(PlanetData.TileFrame.native_available(), "TileFrameNative.cs must load, with Normals")
	assert_true(_frame(_pd, CHUNK_NSIDE, _hp_ipix).native_ok, "the fixture's frame is the C#'s to answer")


## Mountains, cracks, a relief biome and two rocks: every term of both passes on the finest grid, a coarser
## one, and a chunk on the seam of its tile.
func test_synthetic_chunks_are_identical() -> void:
	for chunk: Array in [[CHUNK_NSIDE, _hp_ipix], [CHUNK_NSIDE, _hp_ipix - 1], [CHUNK_NSIDE / 2, _hp_ipix >> 2]]:
		var slow := _mesh_arrays(_pd, chunk[0], chunk[1], RES, false)
		var fast := _mesh_arrays(_pd, chunk[0], chunk[1], RES, true)
		_assert_equal(_compare_arrays(fast, slow), "n%d p%d" % [chunk[0], chunk[1]])


## Not vacuous: the fixture does carve, relieve, raise and colour this chunk.
func test_the_fixture_reaches_every_term() -> void:
	var arrays := _mesh_arrays(_pd, CHUNK_NSIDE, _hp_ipix, RES, true)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var distinct := {}
	for c: Color in colors:
		distinct[c] = true
	assert_gt(distinct.size(), colors.size() / 4, "rock colours, shades all over the chunk")
	var pitch := HEALPix.pixel_side_length(CHUNK_NSIDE, RADIUS) / float(RES)
	assert_true(BiomeRelief.visible_at(_pd.get_biome_by_type(RELIEF_BIOME), pitch), "the relief shows at this pitch")
	var carved := 0
	var core := 0.0
	var frame := _frame(_pd, CHUNK_NSIDE, _hp_ipix)
	for row: PackedVector3Array in HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES):
		for d: Vector3 in row:
			core = maxf(core, _pd.mountain_core(d, frame))
			if _pd.sample_height_for_direction(d, _export_ipix, -1, Vector2i(-1, -1), null, EXPORT_NSIDE, frame, pitch,
					CrackCarve.CARVE) != _pd.sample_height_for_direction(d, _export_ipix, -1, Vector2i(-1, -1), null,
					EXPORT_NSIDE, frame, pitch, CrackCarve.NONE):
				carved += 1
	assert_gt(carved, 0, "the crack network crosses the chunk")
	assert_gt(core, 0.0, "the massif is under the chunk")


## The C# really answers: every vertex of a chunk whose tiles are registered.
func test_it_serves_every_vertex_it_can() -> void:
	var pitch := HEALPix.pixel_side_length(CHUNK_NSIDE, RADIUS) / float(RES)
	var frame := _frame(_pd, CHUNK_NSIDE, _hp_ipix)
	var dirs := _grid(_pd, frame, CHUNK_NSIDE, _hp_ipix, pitch)
	# The probes of the rim reach past it: their tiles too.
	for k: int in HEALPix.get_neighbors_nest(EXPORT_NSIDE, _export_ipix).values():
		if k >= 0:
			frame.entry(k, EXPORT_NSIDE)
	_normals_of(frame, dirs, pitch)
	var served := 0
	for s: int in frame.native.NormalsServed():
		served += s
	assert_eq(served, dirs.size(), "the C# answered every vertex")


## A probe it cannot answer exactly goes back to GDScript: on a frame that knows no tile, nothing is
## served, and the normal is left as the direction for the caller to overwrite.
func test_a_tile_it_does_not_know_goes_back_to_gdscript() -> void:
	var pitch := HEALPix.pixel_side_length(CHUNK_NSIDE, RADIUS) / float(RES)
	var frame := _frame(_pd, CHUNK_NSIDE, _hp_ipix)
	var dirs := PackedVector3Array()
	for row: PackedVector3Array in HEALPix.get_pixel_grid(CHUNK_NSIDE, _hp_ipix, RES):
		dirs.append_array(row)
	var normals := _normals_of(frame, dirs, pitch)
	var served := 0
	for s: int in frame.native.NormalsServed():
		served += s
	assert_eq(served, 0, "nothing is registered yet")
	assert_eq(normals[7], dirs[7], "the placeholder stays")


## Pads are GDScript's: a vertex they moved stays on the GDScript path, its neighbours do not.
func test_a_band_vertex_under_pads_goes_back_to_gdscript() -> void:
	var pitch := HEALPix.pixel_side_length(CHUNK_NSIDE, RADIUS) / float(RES)
	var frame := _frame(_pd, CHUNK_NSIDE, _hp_ipix)
	var dirs := _grid(_pd, frame, CHUNK_NSIDE, _hp_ipix, pitch)
	for k: int in HEALPix.get_neighbors_nest(EXPORT_NSIDE, _export_ipix).values():
		if k >= 0:
			frame.entry(k, EXPORT_NSIDE)
	var band := PackedByteArray()
	band.resize(dirs.size())
	for i: int in range(0, dirs.size(), 3):
		band[i] = 1
	var args: Array = GradeBed.native_args({"pads": [{}], "m_per_deg": 1.0})
	assert_false(args[3], "pads: only GDScript can apply them")
	assert_false(GradeBed.native_args({"villages": [{}], "m_per_deg": 1.0})[3], "a village's ground neither")
	assert_false(GradeBed.native_args({"pieces": [{}], "m_per_deg": 1.0})[3], "pieces with no twin neither")
	assert_true(GradeBed.native_args({"m_per_deg": 1.0})[3], "a context of neither carves nothing: served")
	frame.native.SetNormalGrade(band, args[0], 1.0, args[1], args[2], args[3])
	_normals_of(frame, dirs, pitch)
	var mask: PackedByteArray = frame.native.NormalsServed()
	for i: int in dirs.size():
		assert_eq(mask[i], 0 if band[i] == 1 else 1, "vertex %d" % i)
		if mask[i] != (0 if band[i] == 1 else 1):
			return


## tarsis_3's towns and open ground, on the levels the game streams.
func test_real_chunks_are_identical() -> void:
	var pd: PlanetData = StarMapTiles.offline_data(BODY)
	if pd == null:
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	pd.warm_biome_cache()
	var built := 0
	for poi: Dictionary in StarMapPoi.load_for(BODY):
		var d: Vector3 = poi["dir"]
		if pd.load_chunk_floats(HEALPix.vec2pix_nest(pd.export_nside, d), pd.export_nside).is_empty():
			continue
		for nside: int in [1024, 4096, 8192]:
			var ipix: int = HEALPix.vec2pix_nest(nside, d)
			var slow := _mesh_arrays(pd, nside, ipix, pd.chunk_resolution, false)
			var fast := _mesh_arrays(pd, nside, ipix, pd.chunk_resolution, true)
			_assert_equal(_compare_arrays(fast, slow), "%s n%d" % [str(poi["label"]), nside])
			built += 1
		if built >= 6:
			break
	if built == 0:
		pending("aucune tuile de lieu %s sur cette machine" % BODY)
