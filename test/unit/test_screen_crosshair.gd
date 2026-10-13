extends GutTest
## A 3D screen used with the crosshair (Gui3D.hit / pointer_at / click_at): walking up to a console
## no longer frees the cursor and freezes the view; the ray from the eye points at the interface and
## the `perforate` action clicks it.

var _gui: Node3D
var _button: Button


func before_each() -> void:
	_gui = Node3D.new()
	_gui.set_script(load("res://scenes/interactables/gui_3d.gd"))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(560, 800)
	viewport.disable_3d = true
	_button = Button.new()
	_button.size = Vector2(560, 800)
	viewport.add_child(_button)
	_gui.add_child(viewport)
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.56, 0.8)
	quad.mesh = mesh
	_gui.add_child(quad)
	_gui.node_viewport = viewport
	_gui.node_quad = quad
	add_child_autofree(_gui)


func test_the_crosshair_meets_the_screen_only_in_front_and_within_reach() -> void:
	var centre: Variant = _gui.hit(Vector3(0, 0, 2), Vector3.FORWARD, 4.0)
	assert_not_null(centre, "looking at it from 2 m")
	assert_almost_eq(_gui._uv_of(centre), Vector2(0.5, 0.5), Vector2(0.001, 0.001), "its middle")
	var corner: Variant = _gui.hit(Vector3(-0.2, 0.3, 2), Vector3.FORWARD, 4.0)
	assert_almost_eq(_gui._uv_of(corner), Vector2(0.5 - 0.2 / 0.56, 0.5 - 0.3 / 0.8), Vector2(0.001, 0.001),
			"up-left on the screen is up-left in the interface")
	assert_null(_gui.hit(Vector3(1, 0, 2), Vector3.FORWARD, 4.0), "beside it")
	assert_null(_gui.hit(Vector3(0, 0, 2), Vector3.BACK, 4.0), "looking away")
	assert_null(_gui.hit(Vector3(0, 0, 6), Vector3.FORWARD, 4.0), "out of reach")


func test_a_click_under_the_crosshair_presses_the_button_there() -> void:
	watch_signals(_button)
	var centre: Vector3 = _gui.hit(Vector3(0, 0, 2), Vector3.FORWARD, 4.0)
	_gui.pointer_at(centre)
	_gui.click_at(centre, true)
	_gui.click_at(centre, false)
	assert_signal_emitted(_button, "pressed", "the interface got the click")
