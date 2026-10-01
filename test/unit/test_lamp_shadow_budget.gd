extends GutTest
## LampShadowBudget: only the nearest lamps keep their shadow, the atlas is never full, and two lamps
## at the same distance do not trade the shadow back and forth.

var _camera : Camera3D
var _budget : LampShadowBudget


func before_each() -> void:
	_camera = Camera3D.new()
	add_child_autofree(_camera)
	_camera.make_current()
	_budget = LampShadowBudget.new()
	_budget.max_shadows = 2
	_budget.max_distance = 50.0
	_budget.hysteresis_m = 3.0
	add_child_autofree(_budget)


func _lamp(at: Vector3, shadow: bool = true) -> OmniLight3D:
	var lamp := OmniLight3D.new()
	lamp.shadow_enabled = shadow
	add_child_autofree(lamp)
	lamp.global_position = at
	return lamp


func test_only_the_nearest_keep_their_shadow() -> void:
	var near := _lamp(Vector3(0, 0, -5))
	var middle := _lamp(Vector3(0, 0, -10))
	var far := _lamp(Vector3(0, 0, -20))
	_budget._evaluate()
	assert_true(near.shadow_enabled, "nearest casts")
	assert_true(middle.shadow_enabled, "second casts")
	assert_false(far.shadow_enabled, "third: over the budget, still lit, no shadow")


func test_a_lamp_out_of_range_never_casts() -> void:
	var gone := _lamp(Vector3(0, 0, -80))
	_budget._evaluate()
	assert_false(gone.shadow_enabled, "beyond max_distance")


func test_a_lamp_authored_without_a_shadow_is_left_alone() -> void:
	var plain := _lamp(Vector3(0, 0, -2), false)
	_budget._evaluate()
	assert_false(plain.shadow_enabled, "never given a shadow it was not authored with")


func test_a_lamp_holding_a_shadow_keeps_it_against_a_slightly_nearer_one() -> void:
	var a := _lamp(Vector3(0, 0, -5))
	var b := _lamp(Vector3(0, 0, -10))
	var c := _lamp(Vector3(0, 0, -20))
	_budget._evaluate()
	c.global_position = Vector3(0, 0, -9)  # now 1 m nearer than b: within the head start
	_budget._evaluate()
	assert_true(b.shadow_enabled, "b keeps it")
	assert_false(c.shadow_enabled, "c does not take it for a metre")
	c.global_position = Vector3(0, 0, -4)  # now clearly the nearest
	_budget._evaluate()
	assert_true(c.shadow_enabled, "clearly nearer: it takes a place")
	assert_true(a.shadow_enabled, "and a keeps its own")
	assert_false(b.shadow_enabled, "the farthest gives it up")


func test_the_sun_is_not_a_lamp() -> void:
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	add_child_autofree(sun)
	_budget._evaluate()
	assert_true(sun.shadow_enabled, "directional lights are not budgeted")
