extends GutTest
## PlanetTerrain.drawn_mesh_at: the finest chunk drawn under a direction, found by key one level at a
## time (a walk of every active chunk cost the menu stage 60 ms a second).

const DIR := Vector3(0.3, 0.8, -0.52)


func _terrain(levels: Dictionary) -> PlanetTerrain:
	var t := PlanetTerrain.new()
	t.planet_data = PlanetData.new()
	t.planet_data.radius = 1000.0
	t.planet_data.max_quadtree_depth = 5
	for nside: int in levels:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new() if levels[nside] else null
		autofree(mi)
		t._active_chunks[t._chunk_key_hp(nside, HEALPix.vec2pix_nest(nside, DIR))] = {
			"nside": nside, "ipix": HEALPix.vec2pix_nest(nside, DIR), "mesh_instance": mi}
	autofree(t)
	return t


func test_the_finest_drawn_chunk_wins() -> void:
	var t := _terrain({2: true, 8: true})
	assert_eq(t.drawn_mesh_at(DIR), t._active_chunks[t._chunk_key_hp(8, HEALPix.vec2pix_nest(8, DIR))]["mesh_instance"])


func test_a_chunk_not_drawn_yet_is_skipped() -> void:
	var t := _terrain({2: true, 16: false})
	assert_eq(t.drawn_mesh_at(DIR), t._active_chunks[t._chunk_key_hp(2, HEALPix.vec2pix_nest(2, DIR))]["mesh_instance"])


func test_the_finest_level_counts() -> void:
	var t := _terrain({32: true})
	assert_not_null(t.drawn_mesh_at(DIR), "nside 1 << max_quadtree_depth is looked at")


func test_nothing_drawn_there() -> void:
	var t := _terrain({8: true})
	assert_null(t.drawn_mesh_at(-DIR), "the chunk is on the other side")
