extends GutTest
## LampShadowBudget: only the nearest lamps keep their shadow, the atlas is never full, and two lamps
## at the same distance do not trade the shadow back and forth. A lamp placed in a scene is ranked
## whether its "Shadow" box was ticked or not, and one distance -- the player's -- holds for all.

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
	_budget.distance_option = ""  # the distance set above, not the one of this machine's settings
	add_child_autofree(_budget)


func _lamp(at: Vector3, shadow: bool = true) -> OmniLight3D:
	var lamp := OmniLight3D.new()
	lamp.shadow_enabled = shadow
	add_child_autofree(lamp)
	lamp.global_position = at
	return lamp


## A lamp as a scene brings it: owned by its scene's root, its "Shadow" box left unticked.
func _scene_lamp(at: Vector3, group: StringName = &"") -> OmniLight3D:
	var scene := Node3D.new()
	var lamp := OmniLight3D.new()
	scene.add_child(lamp)
	lamp.owner = scene  # what instantiate() sets, before the scene enters the tree
	if group != &"":
		lamp.add_to_group(group)
	add_child_autofree(scene)
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


func test_a_code_made_light_without_a_shadow_is_left_alone() -> void:
	var glow := _lamp(Vector3(0, 0, -2), false)
	_budget._evaluate()
	assert_false(glow.shadow_enabled, "a neon's glow, a spark: its script built it without one")
	assert_eq(_budget.lamp_count(), 0, "and it takes nobody's place")


func test_a_scene_lamp_casts_whether_its_box_was_ticked_or_not() -> void:
	var street_lamp := _scene_lamp(Vector3(0, 0, -5))
	_budget._evaluate()
	assert_true(street_lamp.shadow_enabled, "the level designer forgot the box: it casts all the same")


func test_a_scene_lamp_is_held_to_the_same_distance_and_count() -> void:
	var near := _scene_lamp(Vector3(0, 0, -5))
	var middle := _lamp(Vector3(0, 0, -10))
	var far := _scene_lamp(Vector3(0, 0, -20))
	var gone := _scene_lamp(Vector3(0, 0, -80))
	_budget._evaluate()
	assert_true(near.shadow_enabled)
	assert_true(middle.shadow_enabled)
	assert_false(far.shadow_enabled, "third: over the budget")
	assert_false(gone.shadow_enabled, "beyond max_distance")


func test_a_scene_lamp_in_the_no_shadow_group_never_casts() -> void:
	var beacon := _scene_lamp(Vector3(0, 0, -2), LampShadowBudget.NO_SHADOW_GROUP)
	_budget._evaluate()
	assert_false(beacon.shadow_enabled, "its author said so")
	assert_eq(_budget.lamp_count(), 0, "and it takes nobody's place")


func test_a_given_shadow_does_not_make_a_lamp_authored() -> void:
	var street_lamp := _scene_lamp(Vector3(0, 0, -5))
	_budget._evaluate()
	var scene := street_lamp.get_parent()
	scene.remove_child(street_lamp)  # carried, reparented: it comes back holding the shadow it was given
	scene.add_child(street_lamp)
	assert_false(street_lamp.has_meta(LampShadowBudget.META_AUTHORED), "still a lamp authored without one")
	assert_eq(_budget.lamp_count(), 1, "and still ranked")


func test_a_distance_of_zero_means_no_lamp_shadow() -> void:
	var near := _lamp(Vector3(0, 0, -1))
	var street_lamp := _scene_lamp(Vector3(0, 0, -2))
	_budget.max_distance = 0.0
	_budget._evaluate()
	assert_false(near.shadow_enabled)
	assert_false(street_lamp.shadow_enabled)


func test_the_distance_follows_the_players_option() -> void:
	var following := LampShadowBudget.new()
	add_child_autofree(following)
	if not following.is_processing():
		pass_test("debug_no_lamp_budget is set in this machine's client.ini: the budget is off")
		return
	SettingsManager.render.set_transient({LampShadowBudget.DISTANCE_OPTION: 20.0})
	assert_eq(following.max_distance, 20.0, "the slider moved: the budget heard it")
	SettingsManager.render.set_transient({})
	assert_eq(following.max_distance,
			float(SettingsManager.render.effective(LampShadowBudget.DISTANCE_OPTION)), "and back")


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


## A headlight as a truck brings it: a scene light authored with a shadow, under the VehicleBody3D.
func _headlight(at: Vector3) -> SpotLight3D:
	var truck := VehicleBody3D.new()
	var light := SpotLight3D.new()
	light.shadow_enabled = true
	truck.add_child(light)
	light.owner = truck
	add_child_autofree(truck)
	truck.global_position = at
	return light


func test_a_parked_truck_headlight_is_ranked_like_a_lamp() -> void:
	var headlight := _headlight(Vector3(0, 0, -5))
	_budget._evaluate()
	assert_true(headlight.shadow_enabled, "the switch is off: the nearest light casts")


func test_the_vehicle_shadow_switch_takes_every_vehicle_light_off() -> void:
	_budget.no_vehicle_shadows = true  # client.ini debug_no_vehicle_light_shadows
	var headlight := _headlight(Vector3(0, 0, -5))
	assert_false(headlight.shadow_enabled, "off as it enters the tree, not one frame with it")
	var lamp := _lamp(Vector3(0, 0, -10))
	_budget._evaluate()
	assert_false(headlight.shadow_enabled, "still off, though the nearest")
	assert_true(lamp.shadow_enabled, "the other lamps are not touched")
