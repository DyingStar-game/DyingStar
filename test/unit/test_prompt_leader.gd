extends GutTest
## PromptLeader: the interaction prompt in a frame beside the crosshair, and a line from the object it is
## about -- from the point the look first met it, held on the object as the head turns.

const LEADER := preload("res://ui/hud/prompt_leader.gd")

var _prompt: Label
var _leader: Control
var _camera: Camera3D
var _ray: RayCast3D
var _body: StaticBody3D
var _shade: Control
var _framed: bool = true  # Settings > General > Framed prompts, as the test sets it


func before_each() -> void:
	var world := Node3D.new()
	add_child_autofree(world)
	_camera = Camera3D.new()
	world.add_child(_camera)
	_camera.current = true
	_ray = RayCast3D.new()
	_ray.target_position = Vector3(0.0, 0.0, -3.0)
	_camera.add_child(_ray)
	# A box a metre and a half ahead, the look on it.
	_body = StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(2.0, 2.0, 0.2)
	_body.add_child(shape)
	_body.position = Vector3(0.0, 0.0, -1.5)
	world.add_child(_body)
	var hud := Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child_autofree(hud)
	_prompt = Label.new()
	_prompt.text = "[F] Ouvrir"
	hud.add_child(_prompt)
	_shade = Control.new()
	hud.add_child(_shade)
	_leader = LEADER.new()
	_leader.framed_rule = func() -> bool: return _framed
	hud.add_child(_leader)
	_leader.follow(_prompt, _camera, _ray, _shade)


func test_it_fades_in_with_the_prompt_and_out_without_it() -> void:
	_prompt.show()
	_leader._process(0.05)
	assert_between(_leader.modulate.a, 0.01, 0.99, "fading in, not snapping")
	_leader._process(1.0)
	assert_eq(_leader.modulate.a, 1.0)
	_prompt.hide()
	_leader._process(1.0)
	assert_eq(_leader.modulate.a, 0.0)


func test_the_frame_sits_up_and_to_the_right_of_the_crosshair() -> void:
	_leader._process(0.016)
	var centre: Vector2 = _leader.get_viewport_rect().size * 0.5
	var frame: Rect2 = _prompt.get_global_rect()
	assert_almost_eq(frame.position.x, centre.x + LEADER.FRAME_OFFSET_PX.x, 0.5, "to the right")
	assert_almost_eq(frame.end.y, centre.y + LEADER.FRAME_OFFSET_PX.y, 0.5, "above")
	assert_not_null(_prompt.get_theme_stylebox("normal") as StyleBoxFlat, "framed, on a dark ground")


func test_the_line_meets_the_frame_at_its_nearest_point() -> void:
	var frame := Rect2(Vector2(100, 100), Vector2(80, 30))
	assert_eq(LEADER.line_end(Vector2(50, 200), frame), Vector2(100, 130), "below-left: its lower-left corner")
	assert_eq(LEADER.line_end(Vector2(50, 115), frame), Vector2(100, 115), "level with it: its left edge")


func test_the_line_starts_on_the_object_and_stays_there_as_the_head_turns() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	_leader._process(0.016)
	assert_eq(_leader._anchor_node, _body, "the line starts on what the look meets")
	var held: Vector3 = _leader._anchor_local
	_camera.rotation_degrees.y = 10.0  # the head turns, the look still on the box
	await get_tree().physics_frame
	await get_tree().physics_frame
	_leader._process(0.016)
	assert_eq(_leader._anchor_node, _body)
	assert_eq(_leader._anchor_local, held, "the same point on it: the line grows, its start stays put")
	assert_almost_eq(held, Vector3.ZERO, Vector3.ONE * 1e-5, "the middle of its box, not where the look met it")
	var start: Vector2 = _camera.unproject_position(_body.to_global(held))
	assert_gt(start.distance_to(_leader.get_viewport_rect().size * 0.5), 5.0, "now off the crosshair")


func test_the_line_starts_at_the_object_s_own_point_wherever_the_look_meets_it() -> void:
	# Taken where the look first met the object, the start jumped about from one look to the next.
	(_body.get_child(0) as CollisionShape3D).position = Vector3(0.3, 0.2, 0.0)  # the box off its body's origin
	var middle := Vector3(0.3, 0.2, 0.0)
	assert_almost_eq(LEADER.anchor_of(_body, Vector3(-0.9, 0.8, 0.1)), middle, Vector3.ONE * 1e-5, "one look")
	assert_almost_eq(LEADER.anchor_of(_body, Vector3(0.7, -0.6, 0.1)), middle, Vector3.ONE * 1e-5, "another")
	var aimed := AimedBody.new()
	add_child_autofree(aimed)
	assert_almost_eq(LEADER.anchor_of(aimed, Vector3.ZERO), Vector3(0.0, 0.5, 0.0), Vector3.ONE * 1e-5,
			"an object that says where it is aimed at: there")


func test_an_object_with_two_boxes_draws_from_the_one_the_look_is_in() -> void:
	# A vehicle's door handle: a box outside the door, one inside the cab. Averaged, the line started in
	# the middle of the door, off the handle.
	var handle := StaticBody3D.new()
	add_child_autofree(handle)
	for at: Vector3 in [Vector3(0.0, 0.0, 0.1), Vector3(0.0, 0.0, -0.1)]:
		var box := CollisionShape3D.new()
		box.shape = BoxShape3D.new()
		(box.shape as BoxShape3D).size = Vector3(0.2, 0.1, 0.05)
		box.position = at
		handle.add_child(box)
	assert_almost_eq(LEADER.anchor_of(handle, Vector3(0.05, 0.02, 0.12)), Vector3(0.0, 0.0, 0.1),
			Vector3.ONE * 1e-5, "outside: the outer box")
	assert_almost_eq(LEADER.anchor_of(handle, Vector3(-0.05, 0.0, -0.09)), Vector3(0.0, 0.0, -0.1),
			Vector3.ONE * 1e-5, "seated: the inner box")


## An object that says where it is aimed at (as a piece of furniture or a seat does).
class AimedBody:
	extends StaticBody3D

	func aim_point() -> Vector3:
		return to_global(Vector3(0.0, 0.5, 0.0))


func test_nothing_under_the_look_leaves_no_line() -> void:
	_body.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_leader._process(0.016)
	assert_null(_leader._anchor_node, "a prompt about nothing under the crosshair: its frame, no line")


func test_turned_off_it_is_the_plain_prompt_of_before_on_its_shade() -> void:
	# Settings > General > Framed prompts, off: the switch shows at once, no restart.
	var plain := Vector2(_prompt.offset_left, _prompt.offset_top)
	assert_false(_shade.visible, "framed: no shade, the frame's own ground")
	_leader._process(0.016)
	_framed = false
	_leader._process(1.0)
	assert_null(_prompt.get_theme_stylebox("normal") as StyleBoxFlat, "no frame")
	assert_eq(Vector2(_prompt.offset_left, _prompt.offset_top), plain, "where the scene places it")
	assert_true(_shade.visible, "on its shade")
	assert_eq(_leader.modulate.a, 0.0, "no line")
	_framed = true
	_leader._process(0.016)
	assert_not_null(_prompt.get_theme_stylebox("normal") as StyleBoxFlat, "framed again")
	assert_false(_shade.visible)


func test_framed_is_the_default() -> void:
	var config := ConfigFile.new()
	assert_true(bool(config.get_value("general", "framed_prompts", true)), "never set: framed")
	assert_true(SettingsManager.has_method("is_framed_prompts_enabled"))


func test_it_never_eats_a_click() -> void:
	assert_eq(_leader.mouse_filter, Control.MOUSE_FILTER_IGNORE)
