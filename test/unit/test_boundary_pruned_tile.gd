extends GutTest

## Two chunks sharing a border must read ONE height there, even when the tile across it is pruned.
##
## sample_height_boundary resolves a border vertex through the tile vec2pix_nest gives it (the
## canonical tile), so both chunks read the same texels. A PRUNED canonical tile has no floats of its
## own — it is read from its published ancestor — and was taken for a missing one: each chunk then
## fell back to its OWN tile, and the two met with a step along the whole border (24.5 cm on tarsis_3
## at 39.519 W 24.736 N, 2026-09-30, mesh and collision alike). test/parity/hole_probe.tscn checks the
## real pack; this checks the rule on a staged one, through the C# half and the GDScript alike.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_boundary_pruned_tile.gd

const NSIDE: int = 1024
const TILE_RES: int = 32


## A sparse pack whose every climb is a pruning for good (see test_tile_frame_native._SparseData).
class _SparseData extends PlanetData:
	func pack_is_sparse() -> bool:
		return true

	func _climb_is_guess(_nside: int, _ipix: int) -> bool:
		return false


func after_each() -> void:
	PlanetData.TileFrame.use_native = true


## The pruned tile B, its parent stored (with the parent's neighbours, for the blend margin) and B's
## eight neighbours stored at B's own level.
func _staged() -> Dictionary:
	var pd := _SparseData.new()
	pd.planet_name = "boundary_pruned"
	pd.radius = 6356000.0
	pd.max_height = 10700.0
	pd.height_offset = -1700.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.chunk_heightmaps_dir = ""
	pd.export_nside = NSIDE
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	@warning_ignore("integer_division")
	var parent_nside: int = NSIDE / 2
	var parent: int = parent_nside * parent_nside * 5 + 777
	var seed_value := 300
	pd.store_chunk_image("hp_n%d_p%d" % [parent_nside, parent], _random_tile(seed_value), [])
	for nb in HEALPix.get_neighbors_nest(parent_nside, parent).values():
		seed_value += 1
		pd.store_chunk_image("hp_n%d_p%d" % [parent_nside, int(nb)], _random_tile(seed_value), [])
	var pruned: int = parent * 4 + 2
	var stored: Array = []
	for nb in HEALPix.get_neighbors_nest(NSIDE, pruned).values():
		if int(nb) < 0:
			continue
		seed_value += 1
		pd.store_chunk_image("hp_n%d_p%d" % [NSIDE, int(nb)], _random_tile(seed_value), [])
		stored.append(int(nb))
	return {"pd": pd, "pruned": pruned, "stored": stored}


## The border vertices of chunk [param ipix] that vec2pix puts in [param ipix] itself.
func _own_border_dirs(ipix: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var res := 32
	var grid: Array = HEALPix.get_pixel_grid(NSIDE, ipix, res)
	for yi in res + 1:
		for xi in res + 1:
			if xi != 0 and xi != res and yi != 0 and yi != res:
				continue
			var d: Vector3 = grid[yi][xi]
			if HEALPix.vec2pix_nest(NSIDE, d) == ipix:
				out.append(d)
	return out


func _frame(pd: PlanetData, native: bool) -> PlanetData.TileFrame:
	PlanetData.TileFrame.use_native = native
	var f: PlanetData.TileFrame = pd.make_tile_frame()
	PlanetData.TileFrame.use_native = true
	return f


func _check(native: bool) -> void:
	var s := _staged()
	var pd: PlanetData = s["pd"]
	var pruned: int = s["pruned"]
	var dirs := _own_border_dirs(pruned)
	assert_gt(dirs.size(), 0, "the pruned tile owns some of its border vertices")
	# Each chunk samples through a frame of its own, as the builders do.
	var own := _frame(pd, native)
	var worst := 0.0
	var compared := 0
	for n: int in s["stored"]:
		var theirs := _frame(pd, native)
		for d in dirs:
			var a := pd.sample_height_boundary(d, pruned, -1, Vector2i(-1, -1), null, NSIDE, own,
					0.0, CrackCarve.NONE)
			var b := pd.sample_height_boundary(d, n, -1, Vector2i(-1, -1), null, NSIDE, theirs,
					0.0, CrackCarve.NONE)
			worst = maxf(worst, absf(a - b))
			compared += 1
	assert_gt(compared, 0)
	assert_eq(worst, 0.0, "%s: one height on the border of a pruned tile, from either side (worst %.4f m)"
			% ["C#" if native else "GDScript", worst])


func test_pruned_canonical_tile_one_height_gdscript() -> void:
	_check(false)


func test_pruned_canonical_tile_one_height_native() -> void:
	if not PlanetData.TileFrame.native_available():
		pending("TileFrameNative assembly not built")
		return
	_check(true)


func _random_tile(seed_value: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for y: int in range(TILE_RES):
		for x: int in range(TILE_RES):
			img.set_pixel(x, y, Color(rng.randf(), 0.0, 0.0))
	return img
