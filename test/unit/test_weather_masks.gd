extends GutTest
## WeatherMasks: a building is boxed by its collision shapes in its own frame, small or flat props are
## not, and the dust layer's box maps the building's own volume onto the unit cube, camera relative.


func _building(size: Vector3, at: Vector3) -> Node3D:
	var root := Node3D.new()
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = at
	body.add_child(cs)
	root.add_child(body)
	add_child_autofree(root)
	return root


func test_a_building_is_boxed_by_its_shapes() -> void:
	var root : Node3D = _building(Vector3(10.0, 4.0, 6.0), Vector3(0.0, 2.0, 0.0))
	WeatherMasks._box(root)
	var box : AABB = root.get_meta(WeatherMasks.META)
	assert_almost_eq(box.size, Vector3(10.0, 4.0, 6.0), Vector3.ONE * 1e-4)
	assert_almost_eq(box.get_center(), Vector3(0.0, 2.0, 0.0), Vector3.ONE * 1e-4)


func test_small_or_flat_props_are_not_masked() -> void:
	var crate : Node3D = _building(Vector3(1.0, 1.0, 1.0), Vector3.ZERO)
	WeatherMasks._box(crate)
	assert_eq(crate.get_meta(WeatherMasks.META), AABB(), "a crate: too small")
	var slab : Node3D = _building(Vector3(20.0, 0.5, 20.0), Vector3.ZERO)
	WeatherMasks._box(slab)
	assert_eq(slab.get_meta(WeatherMasks.META), AABB(), "a slab: too flat")


func test_a_whole_set_is_not_a_building() -> void:
	var set_root : Node3D = _building(Vector3(10.0, 4.0, 6.0), Vector3.ZERO)
	var far := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(4.0, 4.0, 4.0)
	cs.shape = shape
	cs.position = Vector3(5000.0, 0.0, 0.0)  # a piece of the set far away, or not placed yet
	far.add_child(cs)
	set_root.add_child(far)
	WeatherMasks._box(set_root)
	assert_eq(set_root.get_meta(WeatherMasks.META), AABB(), "kilometres wide: never masked")
	var depot : Node3D = _building(Vector3(20.0, 12.0, 95.0), Vector3(0.0, 6.0, 0.0))
	WeatherMasks._box(depot)
	assert_ne(depot.get_meta(WeatherMasks.META), AABB(), "the cargo depot still is")


func test_the_dust_layers_box_maps_the_building_to_the_unit_cube() -> void:
	var root : Node3D = _building(Vector3(10.0, 4.0, 6.0), Vector3(0.0, 2.0, 0.0))
	root.position = Vector3(100.0, 0.0, 50.0)
	WeatherMasks._box(root)
	var masks := WeatherMasks.new(root)
	masks._roots = [root]
	var camera := Vector3(90.0, 1.7, 50.0)
	var m : Projection = masks.masks_for(camera)[0]
	var inside : Vector4 = m * Vector4(100.0 - camera.x, 2.0 - camera.y, 50.0 - camera.z, 1.0)
	assert_lt(absf(inside.x) + absf(inside.y) + absf(inside.z), 1e-4, "the building's centre at the cube's")
	var wall : Vector4 = m * Vector4(105.0 - camera.x, 2.0 - camera.y, 50.0 - camera.z, 1.0)
	assert_almost_eq(wall.x, 0.5, 1e-4, "its wall on the cube's face")
	assert_true(masks.inside(Vector3(101.0, 1.0, 51.0)))
	assert_false(masks.inside(camera))
	masks.free()
