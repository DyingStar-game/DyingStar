extends GutTest
## The DataPad worn on the wrist: F3 raises the arm, the eyes go down to it, and once it is up the view
## eases in on its screen while the tablet (TerminalUI), drawn on that screen, opens -- then used with
## the free cursor, carried onto the screen. Closing it, however, takes the arm back down. The sequence (WristDatapad) is
## stepped by hand here, with a real tablet, a stand-in player and no animator (the raise is then timed);
## a stand-in device stands for the wrist's screen. The mount on the forearm and the network whitelists
## are checked on their own.


## What WristDatapad asks of the Player: the replicated state, its timing, the camera pivot it turns,
## the look sensitivity, and the line to the server.
class FakePlayer:
	extends RefCounted
	var datapad_raised: bool = false
	var datapad_raise_time: float = 0.4
	var camera_sensitivity: float = 1.0
	var camera_pivot: Node3D = null
	var sent: Array = []

	func client_send_action_to_server(data: Dictionary) -> void:
		sent.append(data)


## The wrist screen's Gui3D: a 16:9 screen of `size` metres centred on `at`, in the plane z = at.z, and
## the mouse events it is handed.
class FakeGui:
	extends RefCounted
	var at: Vector3
	var size: Vector2 = Vector2(0.072, 0.0405)
	var pushed: Array = []

	func point_at_uv(uv: Vector2) -> Vector3:
		return at + Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0.0)

	func hit(from: Vector3, dir: Vector3, _reach: float) -> Variant:
		if is_zero_approx(dir.z):
			return null
		var point: Vector3 = from + dir * ((at.z - from.z) / dir.z)
		var off: Vector3 = point - at
		return point if absf(off.x) <= size.x * 0.5 and absf(off.y) <= size.y * 0.5 else null

	func push_at(event: InputEventMouse, point: Vector3) -> void:
		pushed.append([event, point])

	func pointer_left() -> void:
		pass


## What WristDatapad asks of the worn device: its screen, and whether it draws every frame.
class FakeModel:
	extends RefCounted
	var gui := FakeGui.new()
	var live: bool = false

	func screen_global() -> Vector3:
		return gui.at

	func screen_size_m() -> Vector2:
		return gui.size

	func set_live(on: bool) -> void:
		live = on

	var notified: bool = true

	func set_notified(on: bool) -> void:
		notified = on

	func face(_eye: Vector3, _up: Vector3, _amount: float = 1.0) -> void:
		pass

	func rest() -> void:
		pass


var _tablet: TerminalUI
var _camera: Camera3D
var _player: FakePlayer
var _wrist: WristDatapad


## The body, its camera pivot at eye height, the camera on it: the player's look is the pivot's rotation.
func before_each() -> void:
	_tablet = TerminalUI.new()
	add_child_autofree(_tablet)
	var body := Node3D.new()
	add_child_autofree(body)
	var pivot := Node3D.new()
	pivot.position = Vector3(0.0, 1.62, -0.12)
	body.add_child(pivot)
	_camera = Camera3D.new()
	pivot.add_child(_camera)
	_player = FakePlayer.new()
	_player.camera_pivot = pivot
	_wrist = autofree(WristDatapad.new())  # out of the tree: only advance() steps it
	_wrist.setup(_player, _tablet, _camera, null, null)


## Step the sequence through `seconds`, a frame at a time.
func _run(seconds: float) -> void:
	var t: float = 0.0
	while t < seconds:
		_wrist.advance(1.0 / 60.0)
		t += 1.0 / 60.0


## A wrist with a screen in the reading pose, below and in front of the eye.
func _with_screen() -> FakeModel:
	var model := FakeModel.new()
	model.gui.at = Vector3(-0.04, 1.42, -0.38)
	_wrist = autofree(WristDatapad.new())
	_wrist.setup(_player, _tablet, _camera, null, model)
	return model


func test_f3_raises_the_arm_then_eases_into_the_tablet() -> void:
	_wrist.toggle()
	assert_eq(_wrist.phase, WristDatapad.Phase.RAISING)
	assert_true(_player.datapad_raised, "the owner's own arm goes up at once")
	assert_eq(_player.sent, [{"action": "datapad", "on": true}], "and the server is told, to replicate it")
	assert_true(_wrist.is_busy(), "the gesture holds the controls")
	assert_false(_tablet.is_open(), "no tablet before the arm is up")
	_run(_player.datapad_raise_time - 0.05)
	assert_false(_tablet.is_open(), "still on its way up")
	_run(0.07)
	assert_eq(_wrist.phase, WristDatapad.Phase.ZOOMING)
	assert_true(_tablet.is_open(), "on the screen from the start of the zoom")
	assert_true(_wrist.is_busy(), "the zoom still holds the controls")
	_run(WristDatapad.ZOOM_TIME + 0.02)
	assert_eq(_wrist.phase, WristDatapad.Phase.OPEN)
	assert_false(_wrist.is_busy(), "the open tablet holds the controls itself")


func test_f3_during_the_raise_takes_the_arm_back_down() -> void:
	_wrist.toggle()
	_run(0.1)
	_wrist.toggle()
	assert_eq(_wrist.phase, WristDatapad.Phase.LOWERING)
	assert_false(_player.datapad_raised)
	assert_eq(_player.sent.back(), {"action": "datapad", "on": false})
	_run(1.0)
	assert_eq(_wrist.phase, WristDatapad.Phase.LOWERED)
	assert_false(_tablet.is_open(), "the tablet never showed")


func test_closing_the_tablet_any_way_lowers_the_arm() -> void:
	_wrist.toggle()
	_run(1.0)
	assert_true(_tablet.is_open())
	_tablet.close()  # what Escape does, from inside the tablet
	assert_eq(_wrist.phase, WristDatapad.Phase.LOWERING)
	assert_false(_player.datapad_raised)
	_run(1.0)
	assert_eq(_wrist.phase, WristDatapad.Phase.LOWERED)


func test_the_view_eases_in_on_the_screen_and_back_out() -> void:
	var model := _with_screen()
	var pivot: Node3D = _player.camera_pivot
	pivot.rotation = Vector3(0.2, 0.0, 0.0)  # looking a little up
	var want: Vector2 = WristDatapad.look_towards(pivot.position, model.gui.at)
	_wrist.toggle()
	_run(_player.datapad_raise_time + 0.02)
	assert_almost_eq(pivot.rotation.x, want.x, 0.01, "looking down at the screen once the arm is up")
	assert_almost_eq(pivot.rotation.y, want.y, 0.01)
	_run(WristDatapad.ZOOM_TIME * 0.5)
	var halfway: float = _camera.fov
	assert_lt(halfway, SettingsManager.get_fov(), "closing in on the screen")
	_run(WristDatapad.ZOOM_TIME)
	assert_lt(_camera.fov, halfway, "eased, not cut")
	assert_true(model.live, "the screen draws every frame while the tablet is on it")
	var zoomed: float = _camera.fov
	_wrist.close()
	_run(WristDatapad.ZOOM_TIME * 0.5)
	assert_between(_camera.fov, zoomed, SettingsManager.get_fov(), "backing out, eased too")
	assert_false(model.live)
	_run(1.0)
	assert_almost_eq(pivot.rotation.x, 0.2, 0.001, "back where it looked")
	assert_almost_eq(pivot.rotation.y, 0.0, 0.001)
	assert_false(_wrist.is_busy())


func test_the_cursor_is_carried_onto_the_screen() -> void:
	var model := _with_screen()
	add_child_autofree(_wrist)  # in the tree for get_viewport(); still stepped by hand only
	_wrist.set_process(false)
	_wrist.toggle()
	_run(1.0)
	assert_eq(_wrist.phase, WristDatapad.Phase.OPEN)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = _camera.get_viewport().get_visible_rect().size * 0.5  # the cursor mid-window
	_wrist._input(click)
	assert_eq(model.gui.pushed.size(), 1, "the click lands on the wrist's screen")
	var landed: Vector3 = model.gui.pushed.back()[1]
	var look: Vector2 = WristDatapad.look_towards(_player.camera_pivot.position, landed)
	assert_almost_eq(look.x, _player.camera_pivot.rotation.x, 0.01, "where the view's centre is")
	assert_eq(model.gui.pushed.back()[0], click, "the window's own event, carried as it came")


func test_the_eyes_drift_a_little_after_the_cursor() -> void:
	assert_eq(WristDatapad.parallax_uv(Vector2.ZERO), Vector2(0.5, 0.5), "cursor mid-window: the centre")
	var corner: Vector2 = WristDatapad.parallax_uv(Vector2(0.5, -0.5))
	assert_almost_eq(corner.x, 0.5 + 0.5 * WristDatapad.PARALLAX, 0.0001, "towards the cursor, a little")
	assert_almost_eq(corner.y, 0.5 - 0.5 * WristDatapad.PARALLAX, 0.0001)
	assert_eq(WristDatapad.parallax_uv(Vector2(9.0, 0.0)), corner * Vector2(1, 0) + Vector2(0, 0.5),
			"a cursor past the edge drifts no further")


func test_reading_the_wrist_puts_its_light_out() -> void:
	var model := _with_screen()
	assert_true(model.notified, "a notification came in")
	_wrist.toggle()
	_run(_player.datapad_raise_time + 0.02)
	assert_false(model.notified, "read once the arm is up")


func test_f3_during_the_zoom_closes_the_tablet_and_lowers() -> void:
	_wrist.toggle()
	_run(_player.datapad_raise_time + 0.02)
	assert_eq(_wrist.phase, WristDatapad.Phase.ZOOMING)
	_wrist.toggle()
	assert_eq(_wrist.phase, WristDatapad.Phase.LOWERING)
	assert_false(_tablet.is_open(), "the tablet opened with the zoom goes with it")
	assert_false(_player.datapad_raised)


func test_any_way_in_waits_for_the_arm() -> void:
	var opened: Array[String] = []
	_wrist.open_with(func() -> void: opened.append("social"))
	assert_eq(opened, [], "a notification's app waits for the wrist")
	_run(1.0)
	assert_eq(opened, ["social"], "then opens there")
	_wrist.open_with(func() -> void: opened.append("again"))
	assert_eq(opened, ["social", "again"], "already up: at once")


func test_the_look_down_points_at_the_target() -> void:
	assert_eq(WristDatapad.look_towards(Vector3.ZERO, Vector3(0, 0, -1)), Vector2.ZERO, "dead ahead")
	var down: Vector2 = WristDatapad.look_towards(Vector3.ZERO, Vector3(0, -1, -1))
	assert_almost_eq(down.x, -PI / 4.0, 0.0001, "45 degrees down")
	assert_almost_eq(WristDatapad.look_towards(Vector3.ZERO, Vector3(-1, 0, -1)).y, PI / 4.0, 0.0001,
			"a target on the left turns the yaw positive (Godot turns left about +Y)")


func test_the_zoom_leaves_the_housing_in_view() -> void:
	var screen := Vector2(0.072, 0.0405)  # 16:9, like the view: both edges reach it together
	var fov: float = WristDatapad.zoom_fov(screen, 0.3, 16.0 / 9.0, 0.7)
	var expected: float = rad_to_deg(2.0 * atan((0.0405 * 0.5 / 0.7) / 0.3))
	assert_almost_eq(fov, expected, 0.001, "the screen's height is 70 % of the view's")
	assert_lt(WristDatapad.zoom_fov(screen, 0.3, 16.0 / 9.0, 1.0), fov, "filling it all is narrower")


func test_f2_comes_up_on_the_chart() -> void:
	var asked: Array[int] = [0]
	_tablet.navigation_requested.connect(func() -> void: asked[0] += 1)
	_wrist.open(true)
	_run(1.0)
	assert_true(_tablet.is_open())
	assert_eq(asked[0], 1, "the tablet opened on its NAVIGATION tab")


## The device is placed from the arm's REST geometry: +X from elbow to wrist, +Y out of the arm's outer
## side, worn `back_m` up the forearm from the wrist -- whatever the bones' own axes.
func test_the_mount_follows_the_forearm_not_the_bone_axes() -> void:
	var skeleton := Skeleton3D.new()
	add_child_autofree(skeleton)
	var upper: int = skeleton.add_bone("LeftUpperArm")
	var lower: int = skeleton.add_bone("LeftLowerArm")
	var hand: int = skeleton.add_bone("LeftHand")
	skeleton.set_bone_parent(lower, upper)
	skeleton.set_bone_parent(hand, lower)
	# The probe's numbers for this rig (left arm on +X), with an odd bone basis to be ignored.
	var odd := Basis(Vector3.FORWARD, 1.0)
	skeleton.set_bone_rest(upper, Transform3D(odd, Vector3(0.17, 1.45, 0.02)))
	skeleton.set_bone_rest(lower, Transform3D(Basis.IDENTITY, odd.inverse() * Vector3(0.16, -0.18, 0.0)))
	var lower_global: Transform3D = skeleton.get_bone_global_rest(lower)
	var wrist: Vector3 = lower_global.origin + Vector3(0.12, -0.12, 0.16)
	skeleton.set_bone_rest(hand, Transform3D(Basis.IDENTITY, lower_global.affine_inverse() * wrist))
	var mount: Transform3D = WristRaise.mount_transform(skeleton, lower, hand, 0.07)
	var device: Transform3D = skeleton.get_bone_global_rest(lower) * mount
	var along: Vector3 = (wrist - lower_global.origin).normalized()
	assert_almost_eq(device.basis.x.normalized().dot(along), 1.0, 0.001, "+X runs down the forearm")
	assert_almost_eq(device.basis.y.normalized().dot(along), 0.0, 0.001, "+Y is square to it")
	assert_gt(device.basis.y.x, 0.0, "+Y points out of the arm's outer side (+X for the left arm here)")
	assert_almost_eq(device.origin.distance_to(wrist - along * 0.07), 0.0, 0.001, "worn 7 cm up from the wrist")


## The real device: an unread notification beeps, then again every REMIND_S, the light blinking; read,
## both stop.
func test_an_unread_notification_beeps_like_a_pager_until_read() -> void:
	var device: WristDatapadModel = (load("res://scenes/_universe/props/datapad/wrist_datapad.tscn") as PackedScene).instantiate()
	add_child_autofree(device)
	var remind: Timer = device._remind
	assert_true(remind.is_stopped(), "nothing to remind of yet")
	device.set_notified(true)
	assert_false(remind.is_stopped(), "beeping again every few seconds")
	assert_eq(remind.wait_time, WristDatapadModel.REMIND_S)
	assert_true(device.is_processing(), "the light blinks")
	device.set_notified(false)
	assert_true(remind.is_stopped(), "read: quiet")
	assert_false(device.is_processing())
	assert_null(device.led.material_override, "and the light out")


## The seated shake: the wrist's pose is handed to the rig in the skeleton's own space and written as it
## is -- not worked out from world positions 4e10 m out each frame, which came back a few micrometres off
## every time and shook the arm (measured, playtest 2026-10-15).
func test_the_held_pose_reaches_the_rig_exactly_however_far_out() -> void:
	var skeleton := Skeleton3D.new()
	add_child_autofree(skeleton)
	var upper: int = skeleton.add_bone("LeftUpperArm")
	var lower: int = skeleton.add_bone("LeftLowerArm")
	var hand: int = skeleton.add_bone("LeftHand")
	skeleton.set_bone_parent(lower, upper)
	skeleton.set_bone_parent(hand, lower)
	skeleton.set_bone_rest(lower, Transform3D(Basis.IDENTITY, Vector3(0.24, 0.0, 0.0)))
	skeleton.set_bone_rest(hand, Transform3D(Basis.IDENTITY, Vector3(0.24, 0.0, 0.0)))
	var raise: WristRaise = WristRaise.attach(skeleton, upper, lower, hand)
	var wrist := Vector3(0.13, -0.03, -0.36)
	for i: int in 20:
		skeleton.global_position = Vector3(4.1e10, -2.0e10, 6.9e10) + Vector3(sin(i * 1.7), cos(i * 2.3), sin(i)) * 3e-6
		raise.drive(1.0, wrist, Vector3(-0.7, 0.0, 0.0), Vector3(0.0, 0.3, 0.0))
		assert_eq(raise._target.position, wrist, "frame %d: the target is where it was held, to the bit" % i)


## `local_to` multiplies the local transforms up to the ancestor.
func test_local_to_walks_up_the_local_transforms() -> void:
	var top := Node3D.new()
	add_child_autofree(top)
	var middle := Node3D.new()
	middle.transform = Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3))
	top.add_child(middle)
	var leaf := Node3D.new()
	leaf.transform = Transform3D(Basis(Vector3.RIGHT, 0.2), Vector3(0, 0, -1))
	middle.add_child(leaf)
	assert_true(WristRaise.local_to(leaf, top).is_equal_approx(middle.transform * leaf.transform))
	assert_true(WristRaise.local_to(leaf, middle).is_equal_approx(leaf.transform))


## Reading in a parked vehicle: the body's orientation is held against the springs' micro-rocking (a
## micro-radian turn rounds the camera and the arm apart, far out), and let go when the vehicle turns.
func test_the_body_holds_still_under_a_rocking_vehicle_but_follows_a_turn() -> void:
	_with_screen()
	_wrist.toggle()
	_run(1.0)
	var body: Node3D = _player.camera_pivot.get_parent()
	var held: Basis = body.global_basis
	body.global_basis = Basis(Vector3.RIGHT, 5e-5) * held  # the springs: 50 µrad
	_run(1.0 / 60.0)
	assert_true(body.global_basis.is_equal_approx(held), "rocked by 50 µrad: held")
	var turned := Basis(Vector3.UP, 2e-3) * held  # the vehicle turns: 2 mrad
	body.global_basis = turned
	_run(1.0 / 60.0)
	assert_true(body.global_basis.is_equal_approx(turned), "turned by 2 mrad: followed")


func test_the_raised_wrist_is_a_whitelisted_player_property() -> void:
	for path: String in ["res://items_def/player_def.json", "res://addons/dyingstar/network_defs.json"]:
		var text: String = FileAccess.get_file_as_string(path)
		assert_true(text.contains("\"datapad\""), "%s lists datapad: Horizon drops what it does not know" % path)


func test_the_wrist_screen_reads_the_tablet_clock() -> void:
	var pattern := RegEx.create_from_string("^\\d\\d:\\d\\d$")
	assert_not_null(pattern.search(TerminalUI.clock_text()))
