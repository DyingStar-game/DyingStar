extends GutTest
## An apartment's reflection probe is drawn only while the camera is inside its home (InteriorProbe):
## the renderer holds 64 probes on screen and Godot crashes past that, while a village streams in every
## interior within 40 m.

const INTERIOR := "res://scenes/_universe/structures/buildings/apartment_interior.tscn"


func test_inside_the_box_and_its_margin() -> void:
	var box := Vector3(6.1, 2.6, 2.6)
	assert_true(InteriorProbe.holds(Vector3.ZERO, box, 0.0), "middle")
	assert_true(InteriorProbe.holds(Vector3(3.0, 1.2, -1.2), box, 0.0), "in a corner")
	assert_false(InteriorProbe.holds(Vector3(3.5, 0.0, 0.0), box, 0.0), "past the door")
	assert_true(InteriorProbe.holds(Vector3(3.5, 0.0, 0.0), box, 1.0), "past the door, within the margin")
	assert_false(InteriorProbe.holds(Vector3(0.0, 0.0, 2.5), box, 1.0), "in the next home")


func test_the_probe_follows_the_camera() -> void:
	var interior := (load(INTERIOR) as PackedScene).instantiate() as Node3D
	add_child_autofree(interior)
	interior.global_position = Vector3(100.0, 0.0, 0.0)
	var probe := interior.get_node(^"InteriorProbe") as InteriorProbe
	assert_not_null(probe, "the apartment's probe is an InteriorProbe")
	assert_false(probe.visible, "off until a camera comes in")
	probe.refresh(Vector3(97.0, 1.3, 1.3))
	assert_true(probe.visible, "camera inside: on")
	probe.refresh(Vector3(97.0, 1.3, 20.0))
	assert_false(probe.visible, "camera outside: off")
	probe.refresh(Vector3.INF)
	assert_false(probe.visible, "no camera: off")
	KnownEngineErrors.forgive_floor_material(self)
