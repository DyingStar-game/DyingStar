extends GutTest
## The bathroom of a container: shower and toilet doors open to 60 degrees, their ceiling light follows
## the door (on as it opens, out a while after it shuts), and the mirror shows the room from where our
## eye is reflected, our own body through a double that keeps its head.

const SHOWER := "res://scenes/_universe/props/furniture/hygene/shower_cabin.tscn"
const TOILET := "res://scenes/_universe/props/furniture/hygene/restroom_cabin.tscn"
const PUPPET := "res://scenes/_universe/characters/humanoids/human_puppet.tscn"
const MIRROR := "res://scenes/_universe/props/furniture/hygene/mirror.tscn"


func test_cabin_doors_open_to_fifty_degrees() -> void:
	for path: String in [SHOWER, TOILET]:
		var cabin: Node = (load(path) as PackedScene).instantiate()
		var door := cabin.find_child("Door", true, false) as MovingPart
		assert_not_null(door, path)
		assert_eq(absf(door.open_angle_deg), 50.0, path)
		assert_false(door.monitoring, path + ": a passive area")
		cabin.free()


func test_the_ceiling_light_follows_its_door_found_as_it_is() -> void:
	var cabin: Node = (load(SHOWER) as PackedScene).instantiate()
	add_child_autofree(cabin)
	var door := cabin.find_child("Door", true, false) as MovingPart
	var light := cabin.find_child("OmniLight3D", true, false) as Light3D
	assert_false(light.visible, "dark at first")
	door.show_state(true, false)
	assert_true(light.visible, "found open on arrival: lit at once, no strike")
	door.show_state(false, false)
	assert_false(light.visible, "found shut: dark")


func test_the_ceiling_light_goes_out_when_shut_on_nobody() -> void:
	var cabin: Node3D = (load(SHOWER) as PackedScene).instantiate()
	add_child_autofree(cabin)
	var door := cabin.find_child("Door", true, false) as MovingPart
	var light := cabin.find_child("OmniLight3D", true, false) as Light3D
	door.show_state(true, false)
	door.show_state(false, true)
	await wait_seconds(door.duration_s + 0.2)
	assert_false(light.visible, "shut from outside: out once the leaf is home")


func test_the_ceiling_light_stays_on_for_who_is_inside() -> void:
	var cabin: Node3D = (load(SHOWER) as PackedScene).instantiate()
	add_child_autofree(cabin)
	var someone := Node3D.new()
	someone.add_to_group(&"player")
	cabin.add_child(someone)  # standing in the middle of the cabin
	var door := cabin.find_child("Door", true, false) as MovingPart
	var light := cabin.find_child("OmniLight3D", true, false) as Light3D
	door.show_state(true, false)
	door.show_state(false, true)
	await wait_seconds(door.duration_s + 0.2)
	assert_true(light.visible, "shut on someone: still lit")
	someone.position = Vector3(0.0, 0.0, 3.0)  # out (through the wall, for the test)
	await wait_seconds(1.3)
	assert_false(light.visible, "then out once the cabin is empty")


func test_the_mirror_camera_stands_at_the_reflected_eye() -> void:
	var glass := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 0.0))  # +Z out of the glass
	var view: Transform3D = PlanarMirror.reflected_view(glass, Vector3(0.3, 1.6, 2.0))
	assert_almost_eq(view.origin, Vector3(0.3, 1.6, -2.0), Vector3.ONE * 1e-6, "behind the glass, as far")
	assert_almost_eq(-view.basis.z, Vector3(0.0, 0.0, 1.0), Vector3.ONE * 1e-6, "looking into the glass")
	assert_almost_eq(view.basis.determinant(), 1.0, 1e-6, "a true rotation, not a reflection")


func test_the_double_keeps_the_head() -> void:
	var puppet: Node = (load(PUPPET) as PackedScene).instantiate()
	add_child_autofree(puppet)
	var source: Skeleton3D = MirrorDouble._posed_skeleton(puppet)
	assert_not_null(source, "the puppet's skinned skeleton")
	var double := MirrorDouble.new()
	double._copy_from(source)
	source.get_parent().add_child(double)
	assert_eq(double.get_bone_count(), source.get_bone_count())
	var meshes: Array = double.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D)
	assert_gt(meshes.size(), 0, "the body's skinned meshes")
	for mesh: MeshInstance3D in meshes:
		assert_eq(mesh.layers, Globals.RENDER_MASK_MIRROR_DOUBLE, "seen by the mirrors only")
	source.set_bone_pose_scale(source.find_bone("Head"), Vector3.ONE * 0.001)
	double._follow()
	assert_eq(double.get_bone_pose_scale(double.find_bone("Head")), Vector3.ONE, "its head at its true size")


func test_cabin_doors_rest_shut() -> void:
	for path: String in [SHOWER, TOILET]:
		var cabin: Node = (load(path) as PackedScene).instantiate()
		var leaf := (cabin.find_child("Door", true, false) as Node).get_parent() as Node3D
		assert_almost_eq(leaf.rotation.y, 0.0, 1e-6, path + ": shut as the model has it, not left open")
		cabin.free()


## A reflection probe takes one of the 64 slots of the renderer's atlas: one per cabin, two per container,
## a village of them ran out and crashed the client (index -1 in reflection_probe_instance_get_framebuffer).
func test_cabins_carry_no_reflection_probe() -> void:
	for path: String in [SHOWER, TOILET]:
		var cabin: Node = (load(path) as PackedScene).instantiate()
		assert_eq(cabin.find_children("*", "ReflectionProbe", true, false).size(), 0, path)
		cabin.free()


func test_the_mirror_lights_like_a_neon_and_starts_dark() -> void:
	var mirror: Node = (load(MIRROR) as PackedScene).instantiate()
	add_child_autofree(mirror)
	var switch := mirror.find_child("Light", true, false) as LightSwitch
	assert_not_null(switch)
	assert_true(switch.neon)
	var lamp := switch.find_child("OmniLight3D", false, false) as Light3D
	assert_false(lamp.visible, "dark until someone switches it on")
	assert_false(switch.is_on)
	switch.show_state(true, false)
	assert_true(lamp.visible, "found lit on arrival: lit at once, no strike")
	switch.show_state(false, false)
	switch.show_state(true, true)
	assert_false(lamp.visible, "switched on live: the tube strikes before it holds")
	await wait_seconds(1.2)
	assert_true(lamp.visible, "then it holds")


func test_a_mirror_reflects_only_before_it_and_near() -> void:
	var glass := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 0.0))  # +Z out of the glass
	assert_almost_eq(PlanarMirror.reach(glass, Vector3(0.0, 1.5, 2.0), 6.0), 2.0, 1e-6, "before it: its distance")
	assert_eq(PlanarMirror.reach(glass, Vector3(0.0, 1.5, -2.0), 6.0), INF, "behind it: nothing")
	assert_eq(PlanarMirror.reach(glass, Vector3(0.0, 1.5, 8.0), 6.0), INF, "too far: nothing")


func test_the_mirror_renders_without_the_costly_effects() -> void:
	var world := Environment.new()
	world.ssao_enabled = true
	world.ssr_enabled = true
	world.glow_enabled = true
	world.volumetric_fog_enabled = true
	var light: Environment = PlanarMirror.light_environment(world)
	assert_false(light.ssao_enabled or light.ssr_enabled or light.glow_enabled or light.volumetric_fog_enabled)
	assert_true(world.ssao_enabled, "the world's own is untouched")
	assert_same(PlanarMirror.light_environment(world), light, "one copy, shared")


func test_a_mirror_far_from_any_eye_has_no_viewport() -> void:
	var mirror: Node = (load(MIRROR) as PackedScene).instantiate()
	add_child_autofree(mirror)
	await wait_process_frames(2)
	assert_eq(mirror.find_children("*", "SubViewport", true, false).size(), 0, "made only to reflect")
