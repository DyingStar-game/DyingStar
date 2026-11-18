extends GutTest
## SurfaceCatch: the server's below-surface catch asks the real collision before
## throwing a body back onto the theoretical surface. A body standing on collision
## that runs under the theoretical crest stays put (the player hopping on a
## tarsis_3 crater rim); a body that really went through the ground is put back ON
## that ground; with no collision built, the theoretical surface is all there is.
## rescue_dist is the whole decision every net shares (player, truck, mining rocks).

const GlobalsDefs := preload("res://scenes/globals/globals.gd")
## A small "planet": the ground is a slab whose top is at GROUND_R from its centre.
const GROUND_R := 1000.0
const MARGIN := 3.0

## A planet whose theoretical relief is the same everywhere: [member relief] from the centre.
class FlatData extends PlanetData:
	var relief: float = 0.0

	func crack_aware_surface_dist(_dir: Vector3, _nside: int = -1, _vtx_spacing_m: float = 0.0) -> float:
		return relief

	func carved_surface_dist(_dir: Vector3, _memo: Variant = null) -> float:
		return relief


var _planet: Node3D
var _ground: StaticBody3D


func before_each() -> void:
	_planet = Node3D.new()
	add_child_autofree(_planet)
	_planet.global_position = Vector3(5000.0, -200.0, 300.0)
	_ground = StaticBody3D.new()
	_ground.collision_layer = 1 << (GlobalsDefs.LAYER_WORLD - 1)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 10.0, 200.0)
	shape.shape = box
	_ground.add_child(shape)
	_planet.add_child(_ground)
	# Top face at GROUND_R along +Y of the planet frame.
	_ground.position = Vector3(0.0, GROUND_R - 5.0, 0.0)
	await wait_physics_frames(2)


func _ground_dist(theoretical: float, body: float) -> float:
	return SurfaceCatch.ground_dist(get_viewport().world_3d.direct_space_state, _planet, Vector3.UP,
			theoretical, body, MARGIN, [])


func test_a_body_on_the_collision_under_the_crest_stays() -> void:
	# The relief sampled here is 7 m above the triangles the body stands on.
	var g := _ground_dist(GROUND_R + 7.0, GROUND_R)
	assert_almost_eq(g, GROUND_R, 0.01, "the ground found is the one under the feet")
	assert_true(GROUND_R >= g - MARGIN, "standing on it: no catch")


func test_a_body_under_the_ground_is_put_back_on_it() -> void:
	var g := _ground_dist(GROUND_R + 2.0, GROUND_R - 30.0)
	assert_almost_eq(g, GROUND_R, 0.01, "the ground above the body")
	assert_true(GROUND_R - 30.0 < g - MARGIN, "under it: caught, and placed on it")


func test_no_collision_leaves_the_theoretical_surface() -> void:
	_ground.queue_free()
	await wait_physics_frames(2)
	assert_eq(_ground_dist(GROUND_R + 2.0, GROUND_R - 30.0), -1.0)


func _rescue(relief: float, bottom: float) -> float:
	var data := FlatData.new()
	data.relief = relief
	var local := Vector3.UP * bottom
	return SurfaceCatch.rescue_dist(get_viewport().world_3d.direct_space_state, _planet, data, local, bottom,
			_planet.global_transform * local, MARGIN, [])


func test_rescue_leaves_a_body_on_the_ground_alone() -> void:
	assert_eq(_rescue(GROUND_R, GROUND_R), -1.0, "on the ground")
	assert_eq(_rescue(GROUND_R, GROUND_R - MARGIN + 0.5), -1.0, "sunk less than the margin")
	assert_eq(_rescue(GROUND_R, GROUND_R + 20.0), -1.0, "in the air")


func test_rescue_puts_a_body_under_the_ground_back_on_it() -> void:
	assert_almost_eq(_rescue(GROUND_R + 2.0, GROUND_R - 30.0), GROUND_R, 0.01, "on the collision above it")


func test_rescue_leaves_a_body_on_the_collision_under_the_crest() -> void:
	assert_eq(_rescue(GROUND_R + 7.0, GROUND_R), -1.0, "the collision runs under the relief: standing on it")


func test_rescue_with_no_collision_uses_the_theoretical_surface() -> void:
	_ground.queue_free()
	await wait_physics_frames(2)
	assert_almost_eq(_rescue(GROUND_R + 2.0, GROUND_R - 30.0), GROUND_R + 2.0, 0.01)


func test_a_rock_is_measured_from_its_lowest_corner() -> void:
	# A 2 m cube whose box sits off its body's origin (a cut piece), 10 m over a planet centred at the origin.
	var box := AABB(Vector3(-1.0, 0.5, -1.0), Vector3(2.0, 2.0, 2.0))
	var xform := Transform3D(Basis.IDENTITY, Vector3(0.0, 10.0, 0.0))
	assert_almost_eq(RockMining.lowest_dist(box, xform, Vector3.ZERO), Vector3(1.0, 10.5, 1.0).length(), 0.001,
			"the underside's corner, not the origin")
	# Upside down: what was its top is now its underside.
	xform.basis = Basis(Vector3.RIGHT, PI)
	assert_almost_eq(RockMining.lowest_dist(box, xform, Vector3.ZERO), Vector3(1.0, 7.5, 1.0).length(), 0.001)
