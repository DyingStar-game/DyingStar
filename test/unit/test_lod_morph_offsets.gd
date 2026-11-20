extends GutTest
## PlanetChunk.lod_morph_offsets_for: the step from each vertex to the coarser grid's surface.


func _grid(res: int) -> PackedVector3Array:
	var v := PackedVector3Array()
	for y in res + 1:
		for x in res + 1:
			v.append(Vector3(x * 10.0, 0.0, y * 10.0))
	return v


func _step(out: PackedFloat32Array, res: int, x: int, y: int) -> Vector3:
	var i := (y * (res + 1) + x) * 4
	return Vector3(out[i], out[i + 1], out[i + 2])


func _edges(out: PackedFloat32Array, res: int, x: int, y: int) -> int:
	return int(out[(y * (res + 1) + x) * 4 + 3])


func test_a_flat_grid_does_not_move() -> void:
	var out := PlanetChunk.lod_morph_offsets_for(_grid(4), 4)
	assert_eq(out.size(), 25 * 4)
	for i in out.size():
		if i % 4 != 3:
			assert_almost_eq(out[i], 0.0, 1e-5)


func test_odd_vertices_go_to_the_coarse_edge_and_centre() -> void:
	var v := _grid(4)
	v[1 * 5 + 2].y = 6.0  # odd row, even column: between (2,0) and (2,2)
	v[2 * 5 + 1].y = 4.0  # even row, odd column: between (0,2) and (2,2)
	v[1 * 5 + 1].y = 8.0  # cell centre: on the diagonal (2,0)-(0,2)
	v[2 * 5 + 2].y = 2.0  # even, even: a coarse vertex, it stays
	var out := PlanetChunk.lod_morph_offsets_for(v, 4)
	assert_almost_eq(_step(out, 4, 2, 1).y, (0.0 + 2.0) * 0.5 - 6.0, 1e-5)
	assert_almost_eq(_step(out, 4, 1, 2).y, (0.0 + 2.0) * 0.5 - 4.0, 1e-5)
	assert_almost_eq(_step(out, 4, 1, 1).y, -8.0, 1e-5)
	assert_almost_eq(_step(out, 4, 2, 2).y, 0.0, 1e-5)


func test_a_border_vertex_steps_along_its_edge_and_says_which() -> void:
	var v := _grid(4)
	v[0 * 5 + 1].y = 5.0  # odd vertex on the bottom edge
	v.append(Vector3(0.0, -50.0, 0.0))  # a skirt vertex past the grid
	var out := PlanetChunk.lod_morph_offsets_for(v, 4)
	assert_almost_eq(_step(out, 4, 1, 0).y, -5.0, 1e-5)
	assert_eq(_edges(out, 4, 1, 0), PlanetChunk.STITCH_BOTTOM)
	assert_eq(_edges(out, 4, 0, 0), PlanetChunk.STITCH_BOTTOM | PlanetChunk.STITCH_LEFT, "a corner, on two edges")
	assert_eq(_edges(out, 4, 4, 2), PlanetChunk.STITCH_RIGHT)
	assert_eq(_edges(out, 4, 2, 4), PlanetChunk.STITCH_TOP)
	assert_eq(_edges(out, 4, 1, 1), 0, "inside")
	assert_eq(out.size(), v.size() * 4)
	for i in 4:
		assert_almost_eq(out[out.size() - 4 + i], 0.0, 1e-5, "the skirt stays")


func test_half_floats_keep_a_step_and_exact_edge_bits() -> void:
	var packed := PlanetChunk.pack_half4(PackedFloat32Array([-312.4, 0.0, 57.25, 9.0]))
	assert_eq(packed.size(), 8)
	assert_almost_eq(packed.decode_half(0), -312.4, 0.25)
	assert_almost_eq(packed.decode_half(4), 57.25, 0.05)
	assert_eq(packed.decode_half(6), 9.0, "edge bits come back exact")


func test_not_a_grid_gives_nothing() -> void:
	assert_true(PlanetChunk.lod_morph_offsets_for(_grid(3), 3).is_empty(), "odd resolution")
	assert_true(PlanetChunk.lod_morph_offsets_for(PackedVector3Array(), 4).is_empty())
