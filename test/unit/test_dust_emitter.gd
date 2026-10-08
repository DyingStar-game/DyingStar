extends GutTest
## DustEmitter: the anchor the dust lives in follows the actor's GROUND frame, and is replaced rather
## than dragged once the actor is far from it.


func test_the_anchor_holds_near_the_actor_in_the_same_frame() -> void:
	var frame := Node3D.new()
	assert_true(DustEmitter.anchor_holds(frame, frame, Vector3(300.0, 0.0, 0.0)))
	frame.free()


func test_a_far_actor_needs_a_new_anchor() -> void:
	var frame := Node3D.new()
	assert_false(DustEmitter.anchor_holds(frame, frame, Vector3(DustEmitter.ANCHOR_RADIUS_M + 1.0, 0.0, 0.0)))
	frame.free()


func test_an_actor_that_changed_frame_needs_a_new_anchor() -> void:
	var a := Node3D.new()
	var b := Node3D.new()
	assert_false(DustEmitter.anchor_holds(a, b, Vector3.ZERO), "on a truck now, or teleported elsewhere")
	a.free()
	b.free()


func test_a_puff_lays_one_anchor_in_the_actor_s_parent_and_release_removes_it() -> void:
	var frame := Node3D.new()
	add_child_autofree(frame)
	var actor := Node3D.new()
	frame.add_child(actor)
	var dust := SurfaceDust.new()
	dust.amount_by_family = {&"sand": 1.0}
	var emitter := DustEmitter.new(actor, dust)
	emitter.puff(actor.global_position, &"sand", 1.0, Vector3.ZERO)
	emitter.puff(actor.global_position, &"sand", 1.0, Vector3.ZERO)
	var anchors := frame.get_children().filter(func(n: Node) -> bool: return n is GPUParticles3D)
	assert_eq(anchors.size(), 1, "one anchor for every puff")
	var p := anchors[0] as GPUParticles3D
	assert_false(p.emitting, "manual emission only")
	assert_eq(p.amount_ratio, 1.0, "emit_particle emits nothing at amount_ratio 0")
	emitter.release()
	await get_tree().process_frame
	assert_false(is_instance_valid(p))


func test_a_dustless_ground_lays_nothing() -> void:
	var frame := Node3D.new()
	add_child_autofree(frame)
	var actor := Node3D.new()
	frame.add_child(actor)
	var dust := SurfaceDust.new()
	dust.amount_by_family = {&"metal": 0.0}
	var emitter := DustEmitter.new(actor, dust)
	emitter.puff(actor.global_position, &"metal", 1.0, Vector3.ZERO)
	assert_eq(frame.get_child_count(), 1, "only the actor: no anchor for no dust")


## In air the dust sinks with the body's gravity, not with its air's density: held up by the viscosity.
func test_dust_settles_with_the_bodys_gravity() -> void:
	assert_almost_eq(DustEmitter.settle_in_air(0.6, 9.81), 0.6, 1e-6, "Earth: as written")
	assert_almost_eq(DustEmitter.settle_in_air(0.6, 3.14), 0.6 * 3.14 / 9.81, 1e-6, "a light moon: slower")
