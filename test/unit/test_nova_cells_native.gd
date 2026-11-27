extends GutTest
## NovaCellsNative (C#) against its GDScript twin NovaScatter.cell_survivors, and lay_chunk through either:
## the same cells, the same numbers bit for bit, the same objects laid. The server lays its rocks' colliders
## with the same function: a single differing bit would put a collider where the client draws no rock.

const RADIUS := 1000000.0
const NSIDE := 8192
const IPIX := 12345
const RES := 4

var _was: bool = true


func before_each() -> void:
	_was = NovaScatter.native_cells


func after_each() -> void:
	NovaScatter.native_cells = _was


func _native() -> Object:
	var script := NativeScript.load_usable("res://scenes/planet/native/NovaCellsNative.cs", ["CellsInBlocks"])
	assert_not_null(script, "NovaCellsNative.cs must load, or lay_chunk runs the GDScript twin only")
	return script.new() if script != null else null


func test_the_cells_are_the_gdscript_ones_bit_for_bit() -> void:
	var native := _native()
	if native == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Plain layers, clumped ones, a dense one, sparse ones, and faces / positions far out on a fine level.
	for k in 24:
		var layer_seed := rng.randi()
		var density := rng.randf_range(0.02, 1.0)
		var face := rng.randi_range(0, 11)
		var x0 := rng.randi_range(0, (1 << 21) - 64)
		var y0 := rng.randi_range(0, (1 << 21) - 64)
		var r: int = [1, 8, 32, 64][k % 4]
		@warning_ignore("integer_division")
		var clump_cells: int = [1, 1, 4, 16][(k / 4) % 4]
		var share := rng.randf_range(0.1, 0.9)
		# Every block, or a few of a cut of 1 to 8 a side (the client lays the blocks it draws).
		var blocks := mini(r, [1, 2, 4, 8][k % 4])
		var mask: int = NovaScatter.ALL_BLOCKS if k % 3 == 0 else (rng.randi() << 32) | rng.randi()
		var gd := NovaScatter.cell_survivors(layer_seed, density, face, x0, y0, r, clump_cells, share, blocks, mask)
		var cs: PackedFloat64Array = native.CellsInBlocks(layer_seed, density, face, x0, y0, r, clump_cells, share,
				blocks, mask)
		assert_eq(cs.size(), gd.size(), "layer %d: as many cells" % k)
		assert_true(cs == gd, "layer %d: the same numbers, bit for bit" % k)


func test_the_cells_match_cell_object_and_clump_weight() -> void:
	# The twin itself against the functions the rest of the game (and older tests) call one cell at a time.
	var rows := NovaScatter.cell_survivors(42, 0.6, 5, 1000, 2000, 16, 4, 0.5)
	var seen := 0
	for cy in 16:
		for cx in 16:
			var o := NovaScatter.cell_object(42, 0.6, 5, 1000 + cx, 2000 + cy)
			if o.is_empty() or float(o.u_edge) >= NovaScatter.clump_weight(42, 5, o.fx, o.fy, 4, 0.5):
				continue
			var at := seen * NovaScatter.CELL_ROW
			seen += 1
			assert_eq([int(rows[at]), int(rows[at + 1])], [cx, cy], "cell %d,%d in order" % [cx, cy])
			assert_eq([rows[at + 2], rows[at + 3], rows[at + 4], rows[at + 5], rows[at + 6], rows[at + 7],
					rows[at + 8], rows[at + 9], rows[at + 10]],
					[o.fx, o.fy, o.u_mesh, o.u_yaw, o.u_scale, o.u_edge, o.u_spill_turn, o.u_spill_far, o.u_keep])
	assert_eq(rows.size(), seen * NovaScatter.CELL_ROW, "and no other cell")
	assert_gt(seen, 0)


func test_lay_chunk_lays_the_same_rows_either_way() -> void:
	if _native() == null:
		return
	var setup := _chunk()
	var plain: Dictionary = setup.desc
	var clumped := plain.duplicate()
	clumped["seed"] = 1234
	clumped["clump_cells"] = 8
	clumped["clump_share"] = 0.4
	var spilled := plain.duplicate()
	spilled["seed"] = 555
	spilled["spill"] = 0.00002
	var descs := [plain, clumped, spilled]
	# A zone lookup that keeps about half of the objects, through the spilled point.
	var zones := {"variant_at": func(dir: Vector3) -> int: return 0 if dir.x * 1e6 - floorf(dir.x * 1e6) < 0.5 else 3,
			"candidates": {0: true}}
	for solid_only: bool in [false, true]:
		NovaScatter.native_cells = false
		var gd := NovaScatter.lay_chunk(descs, NSIDE, IPIX, RES, setup.grid, setup.vid, setup.center, zones, [],
				solid_only)
		NovaScatter.native_cells = true
		var cs := NovaScatter.lay_chunk(descs, NSIDE, IPIX, RES, setup.grid, setup.vid, setup.center, zones, [],
				solid_only)
		assert_false(gd.is_empty(), "something is laid (solid_only %s)" % solid_only)
		assert_eq(cs.keys(), gd.keys(), "the same blocks (solid_only %s)" % solid_only)
		for key: Array in gd:
			assert_true(cs[key] == gd[key], "the same rows in block %s (solid_only %s)" % [str(key[1]), solid_only])


func test_a_chunk_laid_block_by_block_is_the_chunk_laid_whole() -> void:
	var nside := 1024  # a ~1 km chunk: several blocks of BLOCK_M a side
	var setup := _chunk(nside)
	var d: Dictionary = (setup.desc as Dictionary).duplicate()
	d["view_m"] = 30.0  # small layer: the chunk cut in several blocks a side
	d["view_limit"] = 30.0
	var blocks := NovaScatter.layer_blocks(d, nside, IPIX)
	assert_gt(blocks, 1, "the chunk is cut in blocks")
	var whole := NovaScatter.lay_chunk([d], nside, IPIX, RES, setup.grid, setup.vid, setup.center)
	var pieced := {}
	for b in blocks * blocks:
		var one := NovaScatter.lay_chunk([d], nside, IPIX, RES, setup.grid, setup.vid, setup.center, {}, [], false,
				PackedInt64Array([1 << b]))
		for key: Array in one:
			assert_eq(int(key[1]), b, "a laying of block %d lays nothing else" % b)
			pieced[key] = one[key]
	assert_false(whole.is_empty())
	assert_eq(pieced.keys().size(), whole.keys().size(), "the same blocks")
	for key: Array in whole:
		assert_true(pieced.has(key) and pieced[key] == whole[key], "block %d: the same rows" % int(key[1]))
	assert_eq(NovaScatter.lay_chunk([d], nside, IPIX, RES, setup.grid, setup.vid, setup.center, {}, [], false,
			PackedInt64Array([0])), {}, "mask 0: nothing")


func test_the_blocks_near_the_camera() -> void:
	var setup := _chunk()
	var boxes := NovaScatter.block_boxes(setup.grid, RES, 2)
	assert_eq(boxes.size(), 4)
	for b in 4:
		assert_true(NovaScatter.blocks_within(boxes, boxes[b].get_center(), 0.0) & (1 << b) != 0,
				"a camera inside block %d's box has it" % b)
	var far := boxes[0].get_center() + (boxes[0].get_center() - boxes[3].get_center()) * 10.0
	assert_eq(NovaScatter.blocks_within(boxes, far, 1.0), 0, "a camera far off has none")
	assert_eq(NovaScatter.blocks_within(boxes, far, 1e9), 15, "and all within a huge reach")


## A chunk (level [param nside]) of a 1000 km body with one layer of a 2 m × 1 m × 2 m model on a gently tilted
## grid (as test_nova_rock_collision's).
func _chunk(nside: int = NSIDE) -> Dictionary:
	var dirs: Array = HEALPix.get_pixel_grid(nside, IPIX, RES)
	var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, IPIX) * RADIUS)
	var grid := PackedVector3Array()
	for yi in RES + 1:
		for xi in RES + 1:
			grid.append((dirs[yi][xi] as Vector3) * (RADIUS + 0.5 * xi + 0.2 * yi) - center)
	var vid := PackedInt32Array()
	vid.resize(grid.size())
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.0, 1.0, 2.0)
	var sink := 0.05
	var desc := {
		"variant": 0, "slot": 3, "seed": 99, "nside": nside << 5, "clump_cells": 1, "clump_share": 1.0,
		"cell_side_m": HEALPix.pixel_side_length(nside << 5, RADIUS), "view_m": 300.0, "view_limit": 0.0,
		"spill": 0.0, "density": 0.5, "scale_min": 0.3, "scale_max": 1.5, "sink": sink, "align": 0.5,
		"cos_slope": 0.0, "meshes": [mesh], "heights": PackedFloat32Array([1.0]),
		"reaches": PackedFloat32Array([1.0]),
		"solid_scales": PackedFloat32Array([NovaScatter.solid_scale(mesh.get_aabb(), sink)]),
	}
	return {"grid": grid, "vid": vid, "center": center, "desc": desc}
