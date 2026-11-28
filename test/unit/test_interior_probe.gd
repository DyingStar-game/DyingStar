extends GutTest
## An apartment's reflection probe is drawn only while the camera is inside its home (InteriorProbe):
## the renderer holds a few probes on screen (reflection_count) and Godot crashes past that, while a village streams in every
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


## A crusher's probe lights its metal seen from outside: on from margin_m around its box, off only past
## margin_m + release_m, so walking back and forth over the edge does not draw it again at every step.
func test_a_wide_margin_and_its_release() -> void:
	var probe := InteriorProbe.new()
	probe.size = Vector3(20.0, 20.0, 20.0)
	probe.margin_m = 30.0
	probe.release_m = 10.0
	add_child_autofree(probe)
	probe.refresh(Vector3(45.0, 0.0, 0.0))
	assert_false(probe.visible, "45 m: past the box (10 m) and its margin (30 m)")
	probe.refresh(Vector3(39.0, 0.0, 0.0))
	assert_true(probe.visible, "39 m: within the margin")
	probe.refresh(Vector3(45.0, 0.0, 0.0))
	assert_true(probe.visible, "back to 45 m: still within the release")
	probe.refresh(Vector3(51.0, 0.0, 0.0))
	assert_false(probe.visible, "51 m: past the release")


func test_the_crusher_and_the_refinery_light_their_metal_from_outside() -> void:
	for path: String in ["res://scenes/_universe/structures/industrial/mines/crusher.tscn",
			"res://scenes/_universe/structures/industrial/refinery/refinery.tscn"]:
		var building := (load(path) as PackedScene).instantiate()
		var probe := building.get_node(^"ReflectionProbe") as InteriorProbe
		assert_not_null(probe, "%s: an InteriorProbe" % path)
		if probe != null:
			assert_gt(probe.margin_m, 10.0, "%s: on from outside" % path)
			assert_gt(probe.release_m, 0.0, "%s: not drawn again at every step over the edge" % path)
		building.free()
