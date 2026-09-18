extends GutTest
## Does Godot apply VehicleBody3D.engine_force to EACH driven wheel, or once for the whole body?
##
## The answer decides one line of the drive model — whether the tractive force the design sheet
## gives has to be divided by the number of driven wheels before it is handed to Godot. Getting
## it wrong is a factor of four on a 4x4, and nothing would report it: the truck would simply
## accelerate four times too hard or four times too softly, and someone would "fix" it by tuning
## a magic number back in.
##
## It is measured, not reasoned about: two identical rigs, one with four driven wheels and one
## with two, full throttle from a standstill on flat ground. An A/B answers it without depending
## on suspension losses or tyre friction, which are the same on both.
##
## Run with: godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://test/integration
##   -gselect=test_engine_force_per_wheel

const GRAVITY := 6.867          # Sandbox, and the project default is 0 (gravity is per planet)
const BODY_MASS := 1000.0
const ENGINE_FORCE := 2000.0
const SETTLE_FRAMES := 90       # let the suspension take the weight before touching the throttle
const RUN_FRAMES := 90          # then measure over a window long enough to swamp the first step

var _root: Node3D = null


func before_each() -> void:
	_root = Node3D.new()
	add_child_autofree(_root)
	_root.add_child(_make_floor())
	_root.add_child(_make_gravity_field())


## A wide static slab at y = 0 to drive on.
func _make_floor() -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 2.0, 400.0)
	shape.shape = box
	shape.position = Vector3(0.0, -1.0, 0.0)
	floor_body.add_child(shape)
	return floor_body


## The project runs at zero default gravity (each planet supplies its own), so the rig brings its
## own field. This is the one legitimate use of a monitoring Area3D — a gravity volume.
func _make_gravity_field() -> Area3D:
	var area := Area3D.new()
	area.add_to_group("active_monitor")
	# It must SEE the rig to pull on it: the default mask is layer 1 and the rig sits on the
	# vehicle layer, which is why the first run had zero gravity and four wheels in mid-air.
	area.collision_mask = 0xFFFFF
	area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	area.gravity_direction = Vector3.DOWN
	area.gravity = GRAVITY
	area.priority = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 200.0, 400.0)
	shape.shape = box
	shape.position = Vector3(0.0, 100.0, 0.0)
	area.add_child(shape)
	return area


## A bare VehicleBody3D: a box hull on four wheels. Deliberately NOT the truck scene — this asks a
## question about the ENGINE, and the truck would drag its networking, audio and cargo code in.
func _make_rig(driven_wheels: int) -> VehicleBody3D:
	var body := VehicleBody3D.new()
	body.mass = BODY_MASS
	body.collision_layer = 4
	body.collision_mask = 1
	var hull := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.8, 0.8, 4.0)
	hull.shape = box
	hull.position = Vector3(0.0, 0.8, 0.0)
	body.add_child(hull)
	var i := 0
	for z in [-1.4, 1.4]:
		for x in [-0.8, 0.8]:
			var wheel := VehicleWheel3D.new()
			wheel.position = Vector3(x, 0.35, z)
			wheel.wheel_radius = 0.3
			wheel.wheel_rest_length = 0.3
			wheel.suspension_stiffness = 40.0
			wheel.suspension_max_force = 15000.0
			wheel.damping_compression = 0.4
			wheel.damping_relaxation = 0.8
			wheel.wheel_friction_slip = 3.0
			wheel.use_as_traction = i < driven_wheels
			wheel.use_as_steering = false
			body.add_child(wheel)
			i += 1
	body.position = Vector3(0.0, 0.6, 0.0)
	return body


func _physics_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


## Full throttle from rest; returns the acceleration actually achieved (m/s2).
func _measure_acceleration(driven_wheels: int) -> float:
	var rig := _make_rig(driven_wheels)
	_root.add_child(rig)
	await _physics_frames(SETTLE_FRAMES)
	var contacts: int = 0
	for c in rig.get_children():
		if c is VehicleWheel3D and (c as VehicleWheel3D).is_in_contact():
			contacts += 1
	gut.p("  settle: y = %.3f  v = %.3f  wheels in contact = %d/4  g = %.3f" % [
		rig.global_position.y, rig.linear_velocity.length(), contacts,
		PhysicsServer3D.body_get_direct_state(rig.get_rid()).total_gravity.length()])
	rig.linear_velocity = Vector3.ZERO
	rig.angular_velocity = Vector3.ZERO
	await _physics_frames(2)
	# VehicleBody3D drives toward +Z for a positive engine_force.
	rig.engine_force = ENGINE_FORCE
	var t0: float = Time.get_ticks_usec() / 1_000_000.0
	var v0: float = rig.linear_velocity.z
	await _physics_frames(RUN_FRAMES)
	var v1: float = rig.linear_velocity.z
	var dt: float = Time.get_ticks_usec() / 1_000_000.0 - t0
	rig.engine_force = 0.0
	rig.queue_free()
	if dt <= 0.0:
		return 0.0
	return (v1 - v0) / dt


func test_engine_force_is_applied_to_each_driven_wheel() -> void:
	var a4: float = await _measure_acceleration(4)
	var a2: float = await _measure_acceleration(2)
	gut.p("4 driven wheels: a = %.3f m/s2 (implies %.0f N)" % [a4, a4 * BODY_MASS])
	gut.p("2 driven wheels: a = %.3f m/s2 (implies %.0f N)" % [a2, a2 * BODY_MASS])
	assert_gt(a4, 0.1, "the rig must actually accelerate, otherwise nothing below means anything")
	assert_gt(a2, 0.1, "same for the two-wheel-drive rig")
	# Per wheel => four driven wheels pull twice as hard as two. Whole body => identical.
	var ratio: float = a4 / a2
	gut.p("ratio 4WD / 2WD = %.3f  (2.0 = per wheel, 1.0 = whole body)" % ratio)
	assert_almost_eq(ratio, 2.0, 0.25,
			"engine_force is applied PER DRIVEN WHEEL: the sheet's total force must be divided " +
			"by driven_wheel_count() before it is handed to Godot")


func test_measured_force_matches_engine_force_times_driven_wheels() -> void:
	# The absolute check behind the ratio: with no drag and no rolling resistance modelled while
	# accelerating, mass alone converts acceleration back into force.
	var a4: float = await _measure_acceleration(4)
	var implied: float = a4 * BODY_MASS
	gut.p("implied force = %.0f N for engine_force = %.0f x 4 wheels = %.0f N" % [
		implied, ENGINE_FORCE, ENGINE_FORCE * 4.0])
	assert_almost_eq(implied, ENGINE_FORCE * 4.0, ENGINE_FORCE * 4.0 * 0.25,
			"four driven wheels deliver four times engine_force")
