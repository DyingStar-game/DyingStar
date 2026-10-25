extends GutTest
## CarryPlacement: a load is put down on what it can stand on. Aimed at a floor, the disc lies on it;
## aimed at a wall (a truck's tailgate), it goes to the floor at the wall's foot instead of lying flat
## against it; only a wall-mountable body (a poster) keeps the wall.

const GlobalsDefs := preload("res://scenes/globals/globals.gd")
## The wall's face, along +Z, standing on the floor (top at y = 0).
const WALL_Z := 2.0

var _root: Node3D
var _floor: StaticBody3D
var _wall: StaticBody3D


func before_each() -> void:
	_root = Node3D.new()
	add_child_autofree(_root)
	_root.global_position = Vector3(300.0, 50.0, -700.0)
	_floor = _box(Vector3(20.0, 1.0, 20.0), Vector3(0.0, -0.5, 0.0))
	_wall = _box(Vector3(4.0, 3.0, 0.5), Vector3(0.0, 1.5, WALL_Z + 0.25))
	await wait_physics_frames(2)


func _box(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1 << (GlobalsDefs.LAYER_WORLD - 1)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_root.add_child(body)
	body.position = at
	return body


## Eye at [param from] (local to the root), looking towards [param at].
func _resolve(from: Vector3, at: Vector3, held: Node3D = null) -> Dictionary:
	var eye := Transform3D(Basis.IDENTITY, _root.to_global(from)).looking_at(_root.to_global(at), Vector3.UP)
	return CarryPlacement.resolve(get_viewport().world_3d.direct_space_state, eye, Vector3.UP, [],
			get_tree(), held)


func test_a_floor_takes_the_load() -> void:
	var place := _resolve(Vector3(0.0, 1.6, 0.0), Vector3(0.0, 0.0, 1.0))
	assert_true(place["on_surface"])
	assert_almost_eq((place["normal"] as Vector3).dot(Vector3.UP), 1.0, 0.001)
	assert_almost_eq(_root.to_local(place["position"]).y, 0.0, 0.001)


func test_a_wall_sends_the_load_to_its_foot() -> void:
	var place := _resolve(Vector3(0.0, 1.0, 0.5), Vector3(0.0, 1.0, WALL_Z))
	assert_true(place["on_surface"], "the floor at the foot of the wall")
	assert_almost_eq((place["normal"] as Vector3).dot(Vector3.UP), 1.0, 0.001, "flat, not against the wall")
	var local: Vector3 = _root.to_local(place["position"])
	assert_almost_eq(local.y, 0.0, 0.001)
	assert_lt(local.z, WALL_Z - CarryPlacement.disc_radius(null) + 0.001, "the whole disc clear of the wall")
	assert_eq(place["collider"], _floor)


func test_no_floor_under_the_wall_leaves_it_in_mid_air() -> void:
	_floor.queue_free()
	await wait_physics_frames(2)
	var place := _resolve(Vector3(0.0, 1.0, 0.5), Vector3(0.0, 1.0, WALL_Z))
	assert_false(place["on_surface"])
	assert_lt(_root.to_local(place["position"]).z, WALL_Z, "hanging clear of the wall")


func test_a_poster_keeps_the_wall() -> void:
	var poster := Node3D.new()
	add_child_autofree(poster)
	poster.add_to_group(CarryPlacement.WALL_MOUNTABLE_GROUP)
	var place := _resolve(Vector3(0.0, 1.0, 0.5), Vector3(0.0, 1.0, WALL_Z), poster)
	assert_true(place["on_surface"])
	assert_almost_eq((place["normal"] as Vector3).dot(Vector3.FORWARD), 1.0, 0.001, "against the wall")
	assert_eq(place["collider"], _wall)


func test_stands_on_stops_at_the_slope_limit() -> void:
	var limit := deg_to_rad(CarryPlacement.MAX_SLOPE_DEG)
	assert_true(CarryPlacement.stands_on(Vector3.UP.rotated(Vector3.RIGHT, limit - 0.01), Vector3.UP))
	assert_false(CarryPlacement.stands_on(Vector3.UP.rotated(Vector3.RIGHT, limit + 0.01), Vector3.UP))
	assert_false(CarryPlacement.stands_on(Vector3.DOWN, Vector3.UP), "a ceiling")
