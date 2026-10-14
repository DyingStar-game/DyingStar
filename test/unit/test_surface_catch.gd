extends GutTest
## SurfaceCatch: the server's below-surface catch asks the real collision before
## throwing a body back onto the theoretical surface. A body standing on collision
## that runs under the theoretical crest stays put (the player hopping on a
## tarsis_3 crater rim); a body that really went through the ground is put back ON
## that ground; with no collision built, the theoretical surface is all there is.

const GlobalsDefs := preload("res://scenes/globals/globals.gd")
## A small "planet": the ground is a slab whose top is at GROUND_R from its centre.
const GROUND_R := 1000.0
const MARGIN := 3.0

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
