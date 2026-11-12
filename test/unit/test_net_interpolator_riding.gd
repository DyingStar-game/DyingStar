extends GutTest
## A replica riding a moving parent (a truck on a lift's platform) glides from the pose it drew, not from the one the
## physics server wrote back a step behind the parent: it hopped ~17 cm per step at 10 m/s (playtest 2026-11-12).


func test_a_pose_written_back_does_not_pull_the_rider() -> void:
	var interp := NetInterpolator.new()
	var truck := Node3D.new()
	add_child_autofree(truck)
	interp.set_target(truck, Vector3(0, 0.3, 4), Basis.IDENTITY)  # snaps
	for frame in 10:
		truck.position = Vector3(0, 0.3 + 0.17, 4)  # the physics' write-back, where the parent stood a step before
		interp.update_riding(truck, 1.0 / 60.0)
		assert_almost_eq(truck.position, Vector3(0, 0.3, 4), Vector3.ONE * 1.0e-6, "on its pose, frame %d" % frame)


func test_it_still_glides_to_a_new_target() -> void:
	var interp := NetInterpolator.new()
	var truck := Node3D.new()
	add_child_autofree(truck)
	interp.set_target(truck, Vector3.ZERO, Basis.IDENTITY)
	interp.set_target(truck, Vector3(1, 0, 0), Basis.IDENTITY)
	interp.update_riding(truck, 1.0 / 60.0)
	assert_between(truck.position.x, 0.01, 0.99, "on its way, smoothed")
	interp.snap_next()
	interp.set_target(truck, Vector3(5, 0, 0), Basis.IDENTITY)
	interp.update_riding(truck, 1.0 / 60.0)
	assert_almost_eq(truck.position, Vector3(5, 0, 0), Vector3.ONE * 1.0e-6, "a new frame: from where it was put")
