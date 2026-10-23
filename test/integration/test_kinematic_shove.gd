extends GutTest
## Jolt, measured: why every prop and vehicle is on Globals.MASK_DYNAMIC. A CharacterBody3D (the player)
## is a kinematic body of infinite mass. Walking into an 800 kg block with move_and_slide moves nothing:
## the slide stops the capsule ON the face. But PlayerServer's step-up and climb glides WRITE the
## position, in a straight line from the foot to the top, through the near edge: the capsule ends up
## inside, and Jolt throws the block out of its way (1.07 m for a 0.6 s climb). On MASK_DYNAMIC the
## one-way contact gives the BLOCK the infinite mass instead, and it stays put.

const G := 9.8


func _block_shift(mask: int, climb: bool) -> float:
	var root := Node3D.new()
	add_child_autofree(root)
	var ground := StaticBody3D.new()
	ground.collision_layer = 1 << (Globals.LAYER_WORLD - 1)
	ground.collision_mask = 0
	var gs := CollisionShape3D.new()
	gs.shape = BoxShape3D.new()
	(gs.shape as BoxShape3D).size = Vector3(40, 1, 40)
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	root.add_child(ground)

	var block := RigidBody3D.new()
	block.collision_layer = 1 << (Globals.LAYER_PROP - 1)
	block.collision_mask = mask
	block.mass = 800.0
	block.can_sleep = false
	block.constant_force = Vector3(0, -G * block.mass, 0)  # the project's default gravity is 0
	var bs := CollisionShape3D.new()
	bs.shape = BoxShape3D.new()
	(bs.shape as BoxShape3D).size = Vector3(1, 1, 1)
	block.add_child(bs)
	block.position = Vector3(0, 0.5, 0)
	root.add_child(block)

	var walker := CharacterBody3D.new()
	walker.collision_layer = 1 << (Globals.LAYER_PLAYER - 1)
	walker.collision_mask = Globals.MASK_SOLID
	var ws := CollisionShape3D.new()
	ws.shape = CapsuleShape3D.new()
	walker.add_child(ws)
	walker.position = Vector3(-1.5, 1.0, 0)
	root.add_child(walker)

	await wait_physics_frames(10)  # settle
	var start: Vector3 = block.global_position
	if climb:
		# PlayerServer's climb / step-up glide: the position is WRITTEN, a straight line from the foot of
		# the block to its top, through its near edge, over 0.6 s (vault_duration).
		var from: Vector3 = Vector3(-1.0, 1.0, 0)
		var to: Vector3 = Vector3(0.0, 2.0, 0)
		for i in 36:
			walker.position = from.lerp(to, smoothstep(0.0, 1.0, float(i + 1) / 36.0))
			await wait_physics_frames(1)
		await wait_physics_frames(30)
	else:
		for i in 90:
			walker.velocity = Vector3(3.0, -1.0, 0)
			walker.move_and_slide()
			await wait_physics_frames(1)
	return block.global_position.distance_to(start)


func test_walking_into_a_block_never_shoved_it() -> void:
	# move_and_slide stops the capsule ON the face: no approach speed left for Jolt to hand over.
	var shift: float = await _block_shift(Globals.MASK_SOLID, false)
	assert_lt(shift, 0.02, "the walk alone (moved %.3f m)" % shift)


func test_a_climb_through_the_edge_throws_a_block_that_scans_the_player() -> void:
	var shift: float = await _block_shift(Globals.MASK_SOLID, true)
	assert_gt(shift, 0.2, "800 kg thrown by the gliding capsule (moved %.2f m)" % shift)


func test_a_block_on_mask_dynamic_stays_put_under_the_climb() -> void:
	var shift: float = await _block_shift(Globals.MASK_DYNAMIC, true)
	assert_lt(shift, 0.02, "800 kg does not care about the capsule (moved %.3f m)" % shift)
