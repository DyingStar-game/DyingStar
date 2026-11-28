extends GutTest
## ArrivalPhysics: the physics catch-up held low while arriving, back once the frames settle with the splash
## gone, or after MAX_S; the engine's own value back whatever happens.

const ARRIVAL := preload("res://scenes/globals/arrival_physics.gd")

var _before := 8


func before_each() -> void:
	_before = Engine.max_physics_steps_per_frame


func after_each() -> void:
	Engine.max_physics_steps_per_frame = _before


func _arriving() -> Node:
	var a: Node = ARRIVAL.new()
	add_child_autofree(a)
	a.set_process(false)  # driven by hand
	return a


func test_held_while_the_frames_are_long_or_the_splash_is_up() -> void:
	var a := _arriving()
	assert_eq(Engine.max_physics_steps_per_frame, ARRIVAL.ARRIVAL_STEPS, "held at arrival")
	var t := 0.0
	for k in 100:  # 15 s of 150 ms frames, splash gone: never settled
		t += 0.15
		assert_false(a.step(150.0, t, false))
	for k in 600:  # 10 s of short frames under the splash: not settled either
		t += 0.016
		assert_false(a.step(16.0, t, true))
	assert_eq(Engine.max_physics_steps_per_frame, ARRIVAL.ARRIVAL_STEPS)


func test_released_once_settled() -> void:
	var a := _arriving()
	var t := 0.0
	var released := false
	for k in int(ARRIVAL.SETTLED_S / 0.016) + 2:
		t += 0.016
		released = a.step(16.0, t, false)
		if released:
			break
	assert_true(released, "released after SETTLED_S of short frames")
	assert_eq(Engine.max_physics_steps_per_frame, _before, "the engine's own value back")


func test_a_long_frame_starts_the_calm_over() -> void:
	var a := _arriving()
	for k in int(ARRIVAL.SETTLED_S / 0.016) - 10:
		a.step(16.0, 1.0, false)
	a.step(200.0, 2.0, false)
	for k in 20:
		assert_false(a.step(16.0, 3.0, false), "the calm starts again after a long frame")


func test_released_after_max_s_and_when_freed() -> void:
	var a := _arriving()
	assert_true(a.step(300.0, ARRIVAL.MAX_S + 1.0, false), "released after MAX_S whatever the frames")
	assert_eq(Engine.max_physics_steps_per_frame, _before)
	var b := _arriving()
	assert_eq(Engine.max_physics_steps_per_frame, ARRIVAL.ARRIVAL_STEPS)
	b.free()
	assert_eq(Engine.max_physics_steps_per_frame, _before, "a session left early gives the value back")
