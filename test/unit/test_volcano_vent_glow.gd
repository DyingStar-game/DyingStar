extends GutTest
## The vent's glow (volcano_vent_glow.gd): its light follows the eruption and the plume's drawing, and
## its flank flows run downhill, away from the vent, the same on every client.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_volcano_vent_glow.gd

const VENT_GLOW := preload("res://scenes/planet/volcano/volcano_vent_glow.gd")
const VENT_R := 200.0


## A cone: 2 000 m at the vent, down 0.3 m per metre outward.
static func _cone(x: float, z: float) -> float:
	return 2000.0 - 0.3 * Vector2(x, z).length()


func _glow(seed_v: int = 7) -> Node3D:
	var glow: Node3D = VENT_GLOW.new()
	glow.setup(_cone, VENT_R, seed_v)
	add_child_autofree(glow)
	return glow


func _light(glow: Node3D) -> OmniLight3D:
	return glow.get_node("VentLight") as OmniLight3D


func _lay_all(glow: Node3D) -> MeshInstance3D:
	for i in 400:
		glow.update(0.1, Vector3(3000.0, 1500.0, 0.0), true, 1.0, 1.0)
		if glow.has_node("FlankFlows"):
			break
	return glow.get_node_or_null("FlankFlows") as MeshInstance3D


func test_light_follows_eruption_and_drawing() -> void:
	var glow := _glow()
	glow.update(0.1, Vector3(3000.0, 1500.0, 0.0), true, 0.0, 1.0)
	assert_false(_light(glow).visible, "no light without an eruption")
	glow.update(0.1, Vector3(3000.0, 1500.0, 0.0), true, 1.0, 0.9)
	assert_true(_light(glow).visible, "lit during an eruption")
	assert_almost_eq(_light(glow).light_energy, VENT_GLOW.LIGHT_ENERGY * 0.9, 0.01, "energy = strength x flicker")
	assert_false(_light(glow).shadow_enabled, "never casts shadows")
	glow.update(0.1, Vector3(3000.0, 1500.0, 0.0), false, 1.0, 0.9)
	assert_false(_light(glow).visible, "off when the plume is not drawn")


func test_flows_run_downhill_away_from_the_vent() -> void:
	var glow := _glow()
	var flows := _lay_all(glow)
	assert_not_null(flows, "flows laid near an erupting vent")
	if flows == null:
		return
	var verts: PackedVector3Array = flows.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_gt(verts.size(), VENT_GLOW.FLOW_COUNT * 20, "every flow has a length")
	for v in verts:
		var r := Vector2(v.x, v.z).length()
		assert_gt(r, VENT_R * 0.9, "no flow inside the crater")
		assert_almost_eq(v.y, _cone(v.x, v.z) + VENT_GLOW.FLOW_LIFT_M, 0.5, "laid on the relief")
		if r > VENT_R * 0.9 + VENT_GLOW.FLOW_MAX_M + 100.0:
			fail_test("flow longer than FLOW_MAX_M")
			break


func test_flows_are_the_same_on_every_client() -> void:
	var a := _lay_all(_glow(11))
	var b := _lay_all(_glow(11))
	assert_not_null(a)
	assert_not_null(b)
	if a == null or b == null:
		return
	assert_eq(a.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], b.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX],
			"same seed, same flows")


func test_no_flows_far_away_or_before_an_eruption() -> void:
	var glow := _glow()
	for i in 50:
		glow.update(0.1, Vector3(3000.0, 1500.0, 0.0), true, 0.0, 1.0)
	assert_false(glow.has_node("FlankFlows"), "nothing laid before an eruption")
	for i in 50:
		glow.update(0.1, Vector3(VENT_GLOW.FLOW_BUILD_M * 2.0, 0.0, 0.0), true, 1.0, 1.0)
	assert_false(glow.has_node("FlankFlows"), "nothing laid for a far camera")


func test_flash_envelope_in_two_beats() -> void:
	var env := func(age: float, flicker: float) -> float:
		return VENT_GLOW.flash_envelope(age, 0.1, 1.7, 0.6, flicker)
	assert_eq(env.call(-0.1, 0.0), 0.0, "nothing before the explosion")
	assert_eq(env.call(0.0, 0.0), 1.0, "full at once: light does not wait")
	assert_almost_eq(env.call(0.3, 0.0), 0.6 * exp(-3.0) + 0.4 * exp(-0.3 / 1.7), 0.001, "the white burst is gone")
	assert_between(env.call(1.7, 0.0), 0.4 * exp(-1.0) - 0.001, 0.4 * exp(-1.0) + 0.001, "the red glow at 37 % after 1.7 s")
	assert_lt(env.call(5.5, 0.0), 0.02, "spent within a few seconds")
	assert_eq(env.call(20.0, 0.35), 0.0, "nothing long after")
	for i in 100:
		var age := i * 0.03
		assert_between(env.call(age, 0.35), env.call(age, 0.0) * 0.64, env.call(age, 0.0),
				"the flicker only takes some of it away")


func test_flash_turns_from_white_to_red() -> void:
	assert_gt(VENT_GLOW.flash_whiteness(0.0, 0.1, 1.7, 0.6), 0.55, "white at the burst")
	assert_lt(VENT_GLOW.flash_whiteness(0.5, 0.1, 1.7, 0.6), 0.05, "red once the burst is over")


func test_first_explosion_flashes_brighter() -> void:
	var glow := _glow()
	glow.flash(true, 1.0)
	var first: float = glow.flash_level()
	glow.flash(false, 1.0)
	var later: float = glow.flash_level()
	assert_gt(first, later, "the first explosion of an eruption is the brightest")
	glow.update(0.1, Vector3(3000.0, 1500.0, 0.0), true, 0.0, 1.0)
	assert_true(_light(glow).visible, "a flash lights the vent even without a steady glow")
	for i in 150:
		glow.update(0.1, Vector3(3000.0, 1500.0, 0.0), true, 0.0, 1.0)
	assert_false(_light(glow).visible, "dark again once spent: no floor")
