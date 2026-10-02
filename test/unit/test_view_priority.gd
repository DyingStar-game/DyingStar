extends GutTest
## Build and download order follow the view (PlanetTerrain.build_priority, RemoteTileSource.tile_priority):
## ahead first, behind last, the ground underfoot before both. The cut itself does not change.


func test_a_chunk_ahead_comes_before_one_behind_at_the_same_distance() -> void:
	var view := Vector3.FORWARD
	var ahead := PlanetTerrain.build_priority(Vector3(0, 0, -1000), Vector3.ZERO, view)
	var side := PlanetTerrain.build_priority(Vector3(1000, 0, 0), Vector3.ZERO, view)
	var behind := PlanetTerrain.build_priority(Vector3(0, 0, 1000), Vector3.ZERO, view)
	assert_lt(ahead, side)
	assert_lt(side, behind)
	# Behind counts four times as far: a chunk 1 km behind waits for one 4 km ahead.
	assert_almost_eq(behind, PlanetTerrain.build_priority(Vector3(0, 0, -4000), Vector3.ZERO, view), 1.0)


func test_the_ground_underfoot_still_comes_first() -> void:
	var view := Vector3.FORWARD
	var underfoot := PlanetTerrain.build_priority(Vector3(0, -50, 30), Vector3.ZERO, view)
	var far_ahead := PlanetTerrain.build_priority(Vector3(0, 0, -800), Vector3.ZERO, view)
	assert_lt(underfoot, far_ahead)


func test_without_a_view_it_is_the_distance_alone() -> void:
	assert_eq(PlanetTerrain.build_priority(Vector3(0, 0, 1000), Vector3.ZERO, Vector3.ZERO), 1000000.0)


func test_tiles_ahead_download_before_tiles_behind() -> void:
	var focus := Vector3.UP
	var view := Vector3.FORWARD  # along the ground at the focus
	var ahead := Vector3(0, 1, -0.01).normalized()
	var behind := Vector3(0, 1, 0.01).normalized()
	assert_lt(RemoteTileSource.tile_priority(ahead, focus, view),
			RemoteTileSource.tile_priority(behind, focus, view))
	# Nearest still wins over direction: the tile under the camera first.
	assert_lt(RemoteTileSource.tile_priority(focus, focus, view),
			RemoteTileSource.tile_priority(ahead, focus, view))


func test_looking_straight_down_has_no_preferred_side() -> void:
	var src := RemoteTileSource.new()
	src.set_focus(Vector3.UP, Vector3.DOWN)
	assert_eq(src._focus_view, Vector3.ZERO)
