extends GutTest
## Nothing is seen through a wall (SightLine), however long the wall: how far a ray meets a solid is
## measured where it crosses the shape, not at the shape's centre -- a 6.1 m container wall's centre lies
## metres away from where it is crossed, and a neighbour's furniture behind it read as in sight.

const EYE := Vector3(-0.5, 1.6, 1.3)


## A container's side wall: 6.1 m long, centred 2.55 m from where the eye looks through it.
func _wall() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.1, 2.6, 0.06)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(-3.05, 1.3, 2.57)
	add_child_autofree(body)


func _thing(at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * 0.2
	shape.shape = box
	body.add_child(shape)
	body.position = at
	add_child_autofree(body)
	return body


func test_a_segment_enters_a_box_where_it_crosses_it() -> void:
	var box := AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	assert_almost_eq(SightLine.segment_entry(Vector3(-3, 0, 0), Vector3(3, 0, 0), box), 1.0 / 3.0, 1e-9)
	assert_eq(SightLine.segment_entry(Vector3(-3, 5, 0), Vector3(3, 5, 0), box), INF, "passes over it")
	assert_eq(SightLine.segment_entry(Vector3(0, 0, 0), Vector3(3, 0, 0), box), 0.0, "starts inside")


func test_a_long_wall_hides_what_stands_behind_it() -> void:
	_wall()
	var ray := SightLine.make_ray(self)
	var behind := Vector3(-0.5, 1.0, 3.0)
	assert_true(SightLine.blocked(ray, EYE, behind, []), "the neighbour's drawer, through the wall")
	assert_false(SightLine.first_hit_is(ray, EYE, _thing(behind), []), "nor a part behind it")
	ray.free()


func test_what_stands_before_the_wall_is_seen() -> void:
	_wall()
	var ray := SightLine.make_ray(self)
	var before := Vector3(-0.5, 1.0, 2.2)
	assert_false(SightLine.blocked(ray, EYE, before, []))
	assert_true(SightLine.first_hit_is(ray, EYE, _thing(before), []))
	ray.free()
