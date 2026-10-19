extends GutTest
## A planet's own physics space stops stepping while nothing in it can move, wakes as soon as a body
## arrives, and stays queryable while asleep (PlanetSpaceGate).

var _gate: PlanetSpaceGate
var _world: SubViewport


func before_each() -> void:
	_world = SubViewport.new()
	_world.own_world_3d = true
	_world.size = Vector2i(2, 2)
	_world.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autofree(_world)
	_gate = PlanetSpaceGate.new()
	_gate.sleep_delay_ms = 0
	_gate.bind(get_tree())


func _space() -> RID:
	return _world.find_world_3d().space


func _floor() -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	return floor_body


func _box() -> RigidBody3D:
	var body := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	body.add_child(cs)
	body.position = Vector3(0.0, 5.0, 0.0)
	return body


func test_an_empty_world_falls_asleep() -> void:
	_world.add_child(_floor())
	_gate.register(_world, "test")
	_gate.tick()
	assert_false(PhysicsServer3D.space_is_active(_space()), "static ground only: nothing to step")
	assert_eq(_gate.active_count(), 0)


func test_a_world_with_a_body_stays_awake() -> void:
	_world.add_child(_box())
	_gate.register(_world, "test")
	_gate.tick()
	assert_true(PhysicsServer3D.space_is_active(_space()), "a body was already there at registration")


func test_a_body_arriving_wakes_the_world_and_leaving_lets_it_sleep() -> void:
	_gate.register(_world, "test")
	_gate.tick()
	assert_false(PhysicsServer3D.space_is_active(_space()))
	var body := _box()
	_world.add_child(body)
	await wait_physics_frames(1)
	assert_true(PhysicsServer3D.space_is_active(_space()), "woken before the body's next step")
	_world.remove_child(body)
	body.free()
	_gate.tick()
	assert_false(PhysicsServer3D.space_is_active(_space()), "empty again")


func test_a_reparent_between_two_worlds_moves_the_count() -> void:
	var other := SubViewport.new()
	other.own_world_3d = true
	add_child_autofree(other)
	_gate.register(_world, "a")
	_gate.register(other, "b")
	var body := _box()
	_world.add_child(body)
	body.reparent(other)
	await wait_physics_frames(1)
	_gate.tick()
	assert_false(PhysicsServer3D.space_is_active(_space()), "the body left: a sleeps")
	assert_true(PhysicsServer3D.space_is_active(other.find_world_3d().space), "the body arrived: b wakes")


func test_the_empty_delay_keeps_a_world_awake() -> void:
	_gate.sleep_delay_ms = 60_000
	_gate.register(_world, "test")
	_gate.tick()
	assert_true(PhysicsServer3D.space_is_active(_space()), "not empty for long enough yet")


func test_a_sleeping_world_still_answers_raycasts() -> void:
	_gate.register(_world, "test")
	_gate.tick()
	# Added AFTER the space went to sleep, like a terrain chunk built for a spawn check.
	_world.add_child(_floor())
	var query := PhysicsRayQueryParameters3D.create(Vector3(0.0, 10.0, 0.0), Vector3(0.0, -10.0, 0.0))
	var hit: Dictionary = _world.find_world_3d().direct_space_state.intersect_ray(query)
	assert_false(PhysicsServer3D.space_is_active(_space()))
	assert_false(hit.is_empty(), "the ground of an asleep space is still found")
