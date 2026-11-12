extends GutTest
## The walk back after a mine layer falls (PlayerServer.retreat): the walk key that takes the body the asked way,
## whichever way it faces -- it keeps looking at the face and walks backwards (playtest 2026-11-11).


func _move(body_basis: Basis, key: Vector2) -> Vector3:
	# What the server's walk does with a key (PlayerServer._physics_process: move_direction).
	return (body_basis * Vector3(key.x, 0.0, key.y)).normalized()


func test_facing_the_face_it_walks_backwards() -> void:
	var facing_face := Basis.IDENTITY  # looks down -Z, the face; the gallery's way out is +Z
	var key := PlayerServer.retreat_input(facing_face, Vector3.BACK)
	assert_almost_eq(key, Vector2(0.0, 1.0), Vector2.ONE * 1.0e-6, "the back key")
	assert_almost_eq(_move(facing_face, key), Vector3.BACK, Vector3.ONE * 1.0e-6)


func test_whichever_way_it_looks_it_goes_down_the_gallery() -> void:
	var out := Vector3(1.0, 0.0, 2.0).normalized()
	for yaw: float in [0.0, 0.7, 1.6, 3.0, -2.2]:
		var body := Basis(Vector3.UP, yaw)
		var key := PlayerServer.retreat_input(body, out)
		assert_almost_eq(key.length(), 1.0, 1.0e-6, "a full key at yaw %.1f" % yaw)
		assert_almost_eq(_move(body, key), out, Vector3.ONE * 1.0e-5, "down the gallery at yaw %.1f" % yaw)


func test_straight_up_is_no_key() -> void:
	assert_eq(PlayerServer.retreat_input(Basis.IDENTITY, Vector3.UP), Vector2.ZERO)
