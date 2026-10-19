extends GutTest
## The cab's switchable screen (the truck's middle one): its mode goes camera -> chart -> off and travels
## as one key, a screen shows what its power and mode say, and the truck's screen mesh is one the
## crosshair can point through its UVs (Gui3D.uv_frame).

const TRUCK_MODEL := "res://assets/_universe/vehicles/ground/mini_truck.glb"
const GUI_3D := preload("res://scenes/interactables/gui_3d.gd")


## Playtest 2026-10-19: OFFLINE by default, then the chart, then the camera, then OFFLINE again.
func test_the_key_cycles_offline_chart_camera() -> void:
	var mode := VehicleScreenMode.new()
	assert_eq(mode.mode, VehicleScreenMode.Mode.OFF, "a new truck's screen is OFFLINE")
	mode.cycle()
	assert_eq(mode.mode, VehicleScreenMode.Mode.MAP, "first press: the chart")
	mode.cycle()
	assert_eq(mode.mode, VehicleScreenMode.Mode.CAMERA, "second: the rear camera")
	mode.cycle()
	assert_eq(mode.mode, VehicleScreenMode.Mode.OFF, "and OFFLINE again")


func test_only_a_change_is_sent_and_a_received_float_is_read() -> void:
	var mode := VehicleScreenMode.new()
	var data := {}
	mode.write_changes(data)
	assert_eq(data, {VehicleScreenMode.KEY: int(VehicleScreenMode.Mode.OFF)}, "the first call sends the mode")
	data = {}
	mode.write_changes(data)
	assert_true(data.is_empty(), "unchanged: nothing")
	var replica := VehicleScreenMode.new()
	replica.read({VehicleScreenMode.KEY: 2.0})  # Godot's JSON hands integers back as floats
	assert_eq(replica.mode, VehicleScreenMode.Mode.CAMERA)
	data = {}
	replica.write_changes(data)
	assert_true(data.is_empty(), "a received value is not sent back")
	replica.read({VehicleScreenMode.KEY: 9.0})
	assert_eq(replica.mode, VehicleScreenMode.Mode.CAMERA, "out of range: kept inside the modes")


func test_a_screen_shows_what_power_and_mode_say() -> void:
	assert_eq(RearCamera.shown_for(false, VehicleScreenMode.Mode.MAP), RearCamera.Shown.OFF, "no power, dark")
	assert_eq(RearCamera.shown_for(true, VehicleScreenMode.Mode.CAMERA), RearCamera.Shown.FEED)
	assert_eq(RearCamera.shown_for(true, VehicleScreenMode.Mode.MAP), RearCamera.Shown.MAP)
	assert_eq(RearCamera.shown_for(true, VehicleScreenMode.Mode.OFF), RearCamera.Shown.OFFLINE,
			"switched off but powered: OFFLINE written on it")


## Playtest 2026-10-19: backing up shows the rear camera whatever the mode, power permitting.
func test_backing_up_shows_the_feed_in_every_mode() -> void:
	for value: int in VehicleScreenMode.Mode.values():
		assert_eq(RearCamera.shown_for(true, value, true), RearCamera.Shown.FEED, "mode %d, reversing" % value)
	assert_eq(RearCamera.shown_for(false, VehicleScreenMode.Mode.MAP, true), RearCamera.Shown.OFF,
			"no power: still dark")


func test_the_reversing_feed_holds_a_moment_after_the_wheels_stop() -> void:
	var left: float = RearCamera.reverse_time_left(0.0, -3.0, 0.5, 2.0, 0.1)
	assert_eq(left, 2.0, "turning backwards: held for the whole hold")
	left = RearCamera.reverse_time_left(left, 0.0, 0.5, 2.0, 0.5)
	assert_almost_eq(left, 1.5, 1e-6, "stopped: counting down")
	left = RearCamera.reverse_time_left(left, -0.2, 0.5, 2.0, 2.0)
	assert_eq(left, 0.0, "a truck settling backwards is not reversing")
	assert_eq(RearCamera.reverse_time_left(0.0, 20.0, 0.5, 2.0, 0.1), 0.0, "driving forwards: never")


func test_every_mode_has_its_prompt() -> void:
	for value: int in VehicleScreenMode.Mode.values():
		assert_true(CabScreenPointer.MODE_KEYS.has(value), "mode %d has a prompt" % value)


## The truck's middle screen leans ~33 degrees inside its own mesh, so the crosshair points it through
## its UVs (Gui3D.uv_frame): every vertex of the screen must come back at its own UV, and lie on the one
## plane the hit is taken on. Measured on the real model.
func test_the_truck_middle_screen_is_pointed_through_its_uvs() -> void:
	var model: Node = (load(TRUCK_MODEL) as PackedScene).instantiate()
	var screen := model.find_child("Screen_Rear", true, false) as MeshInstance3D
	assert_not_null(screen, "the model has its middle screen")
	if screen != null:
		var arrays: Array = screen.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var frame: Array = GUI_3D.frame_from(verts, uvs)
		var normal: Vector3 = (frame[1] as Vector3).cross(frame[2]).normalized()
		for i: int in verts.size():
			assert_almost_eq(GUI_3D.uv_in_frame(verts[i], frame), uvs[i], Vector2(1e-3, 1e-3),
					"vertex %d back at its UV" % i)
			assert_almost_eq((verts[i] - (frame[0] as Vector3)).dot(normal), 0.0, 1e-4, "flat: on the plane")
	model.free()


func test_a_unit_quad_frame_reads_back_its_corners() -> void:
	var verts := PackedVector3Array([Vector3(-1, 1, 0), Vector3(1, 1, 0), Vector3(-1, -1, 0)])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
	var frame: Array = GUI_3D.frame_from(verts, uvs)
	assert_almost_eq(GUI_3D.uv_in_frame(Vector3(0, 0, 0), frame), Vector2(0.5, 0.5), Vector2(1e-6, 1e-6))
	assert_almost_eq(GUI_3D.uv_in_frame(Vector3(1, -1, 0.3), frame), Vector2(1, 1), Vector2(1e-6, 1e-6),
			"off the plane: its foot on it")


## The chart's view on the cab screen is shared (VehicleChartView): only a view's own fields travel, and
## only when they changed; a client's dictionary is cleaned, never trusted.
func test_a_shared_view_keeps_only_its_own_fields() -> void:
	var clean: Dictionary = VehicleChartView.clean_view({"zoom": 2.5, "yaw": 1, "watch": "tarsis_3",
			"pitch": NAN, "script": "boom", "select": 12})
	assert_eq(clean, {"zoom": 2.5, "yaw": 1.0, "watch": "tarsis_3"}, "numbers finite, names strings, nothing else")


func test_a_shared_view_is_sent_once_and_read_back() -> void:
	var part := VehicleChartView.new()
	assert_true(part.set_view({"zoom": 3.0, "watch": "tarsis_3"}))
	assert_false(part.set_view({"zoom": 3.0, "watch": "tarsis_3"}), "the same view: no change")
	var data := {}
	part.write_changes(data)
	assert_eq(data, {VehicleChartView.KEY: {"zoom": 3.0, "watch": "tarsis_3"}})
	data = {}
	part.write_changes(data)
	assert_true(data.is_empty(), "unchanged: nothing sent")
	var replica := VehicleChartView.new()
	replica.read({VehicleChartView.KEY: {"zoom": 3.0, "watch": "tarsis_3"}})
	assert_eq(replica.view, part.view)


func test_the_chart_camera_stands_where_a_view_says_at_once() -> void:
	var from := StarMapCamera.new()
	from.zoom = 4.0
	from.yaw = 0.7
	from.pitch = -0.3
	var to := StarMapCamera.new()
	to.restore(from.snapshot())
	assert_eq(to.snapshot(), from.snapshot())
	assert_false(to.is_travelling(), "shown as it is, not travelled to")
