extends GutTest
## A reparent (onto a vehicle lift's platform, through the teleporter) must not unmount the wheels: a
## VehicleWheel3D reads its mount and its ray direction from its own transform when it enters the tree,
## and the physics rewrites that transform every step with the spinning wheel (Vehicle._restore_wheel_mounts).

const TRUCK := "res://scenes/_universe/vehicles/ground/trucks/truck.tscn"


## The project has no default gravity (the planets bring theirs): a directional area, like a station's.
func _gravity() -> Area3D:
	var area := Area3D.new()
	area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	area.gravity_direction = Vector3.DOWN
	area.gravity = 9.8
	area.collision_mask = 0xFFFF  # an area acts on what it detects: the truck is on the vehicle layer
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 50.0, 200.0)
	cs.shape = box
	area.add_child(cs)
	return area


func _floor() -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	return floor_body


func _in_contact(truck: VehicleBody3D) -> int:
	var n := 0
	for w: VehicleWheel3D in truck.find_children("*", "VehicleWheel3D", false, false):
		if w.is_in_contact():
			n += 1
	return n


func test_the_wheels_still_reach_the_ground_after_a_reparent() -> void:
	var a := Node3D.new()
	var b := Node3D.new()
	add_child_autofree(a)
	add_child_autofree(b)
	a.add_child(_floor())
	a.add_child(_gravity())
	var truck := (load(TRUCK) as PackedScene).instantiate() as VehicleBody3D
	truck.position = Vector3(0.0, 1.2, 0.0)
	a.add_child(truck)
	truck.freeze = false  # off the network a truck is a frozen set piece (Vehicle._process)
	await wait_physics_frames(90)
	assert_eq(_in_contact(truck), 4, "settled on its four wheels")
	# What the physics writes into a wheel's transform every step: the hub hanging on its spring, the
	# wheel turned on its axle. Half a turn here, as a truck rolling onto the platform has any angle.
	for w: VehicleWheel3D in truck.find_children("*", "VehicleWheel3D", false, false):
		w.transform = Transform3D(w.transform.basis.rotated(Vector3.RIGHT, 2.5), w.transform.origin + Vector3.DOWN * 0.2)
	truck.reparent(b)
	await wait_physics_frames(10)
	assert_eq(_in_contact(truck), 4, "the four wheels still meet the ground after the reparent")
	for w: VehicleWheel3D in truck.find_children("*", "VehicleWheel3D", false, false):
		if w.has_meta(Vehicle.WHEEL_MOUNT_META):
			var ray_dir: Vector3 = -(w.get_meta(Vehicle.WHEEL_MOUNT_META) as Transform3D).basis.y
			assert_almost_eq(ray_dir.dot(Vector3.DOWN), 1.0, 0.001, "%s mounted straight down" % w.name)
