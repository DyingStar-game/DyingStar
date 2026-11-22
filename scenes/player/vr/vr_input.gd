class_name VrInput
extends Node
## The VR controllers, played as a gamepad: each frame their sticks, triggers and buttons become the
## events of an Xbox-style pad (Input.parse_input_event), so every action the game already binds on the
## gamepad -- walk, jump, crouch, the action key that also gets out of bed, the tool, the vehicle, the
## pause menu -- works from any headset's controllers, rebinding included, with no gameplay code to
## change. The buttons are read through the action map's actions (xr/openxr_action_map.tres), which
## exist on every controller profile, so the same physical labels do the same thing everywhere.
##
## Two things are VR's own: the right stick turns the body in steps (comfort: a smooth turn the eyes do
## not feel makes many players sick; looking up and down is the head's), and a click of the left stick
## runs until the stick comes back to the centre (holding a stick down while pushing it is tiring).
##
## Built by VrRig for the owner's player, in VR only.

## The pad's device id for the events we make: a number no real pad gets, so the game can tell them
## apart (every gamepad binding of the project is for all devices, -1, and takes them).
const DEVICE := XRMode.PAD_DEVICE
## Each step of the snap turn (deg).
const SNAP_TURN_DEG := 30.0
## The right stick turns past this (0..1), and re-arms under SNAP_REARM.
const SNAP_PUSH := 0.7
## How far back (0..1) the right stick must come before the next step.
const SNAP_REARM := 0.3
## Held this long (s), the right stick's click recentres the view (VrBody.recenter), hands free only: a
## load in the hands takes it to turn the load.
const RECENTER_HOLD_S := 1.0
## Analog values closer than this to the last one sent are not sent again (no event flood).
const AXIS_EPSILON := 0.01
## The run a left stick click starts lasts while the stick is pushed past this (0..1), on foot.
const RUN_HOLD := 0.2

## [action of the action map, hand (0 left / 1 right), pad button]. Laid out by what is PRINTED on the
## controllers, like an Xbox pad: A and B under the right thumb, X and Y under the left one (Touch, Pico,
## Windows MR); the Steam Frame carries all four on the right, and its d-pad and View on the left.
const BUTTONS: Array = [
	[&"ax_button", 1, JOY_BUTTON_A],  # jump (A)
	[&"by_button", 1, JOY_BUTTON_B],  # crouch, cancel (B)
	[&"ax_button", 0, JOY_BUTTON_X],  # the action key: use, pick up, get out of bed (X)
	[&"x_button", 1, JOY_BUTTON_X],  # Steam Frame: X on the right controller
	[&"squeeze_click", 1, JOY_BUTTON_X],  # closing the right hand uses what it points at too
	[&"by_button", 0, JOY_BUTTON_Y],  # get out, tool (Y)
	[&"y_button", 1, JOY_BUTTON_Y],  # Steam Frame: Y on the right controller
	[&"menu_button", 0, JOY_BUTTON_START],  # pause (Touch, Pico: menu on the left)
	[&"menu_button", 1, JOY_BUTTON_START],  # pause (Steam Frame: menu on the right)
	[&"select_button", 0, JOY_BUTTON_BACK],  # star map (Steam Frame: View)
	[&"primary_click", 0, JOY_BUTTON_LEFT_STICK],  # sprint
	[&"primary_click", 1, JOY_BUTTON_RIGHT_STICK],
	[&"bumper", 0, JOY_BUTTON_LEFT_SHOULDER],  # roll, carried crate's rotation
	[&"bumper", 1, JOY_BUTTON_RIGHT_SHOULDER],
	[&"squeeze_click", 0, JOY_BUTTON_LEFT_SHOULDER],  # controllers with no bumper: the left grip
	[&"dpad_up", 0, JOY_BUTTON_DPAD_UP],  # torch
	[&"dpad_down", 0, JOY_BUTTON_DPAD_DOWN],  # prone, head lights
	[&"dpad_left", 0, JOY_BUTTON_DPAD_LEFT],  # emote wheel
	[&"dpad_right", 0, JOY_BUTTON_DPAD_RIGHT],  # ignition
]
## While a menu has the mouse (the laser points), only these reach the game: pause and back close it.
## The bumpers step the menus' tabs (ui_page_previous / ui_page_next).
const BUTTONS_IN_MENUS: Array[JoyButton] = [
	JOY_BUTTON_START, JOY_BUTTON_B, JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER,
]

## Does a menu have the mouse (the laser points at it)? Then only BUTTONS_IN_MENUS reach the game. A
## Callable so the tests can play without a window (headless, the mouse is never captured).
var menu_has_mouse: Callable = func() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_VISIBLE or Input.mouse_mode == Input.MOUSE_MODE_CONFINED

var _player: Node3D = null
var _hands: Array[XRController3D] = []
var _buttons_down: Dictionary = {}  # JoyButton -> bool, as last sent
var _axes_sent: Dictionary = {}  # JoyAxis -> float, as last sent
var _snap_armed: bool = true
var _running: bool = false  # a left stick click is running (RUN_HOLD)
var _body: VrBody = null
var _recenter_held: float = 0.0  # how long the right stick has been held down (s); -1 once used


## Read [param left] and [param right] (the rig's hands) for [param player] (a Player: its
## mouse_motion takes the snap turn, as the mouse's would). [param body] (optional) adds its catch-up
## walk to the stick and recentres on a long press.
func setup(player: Node3D, left: XRController3D, right: XRController3D, body: VrBody = null) -> void:
	_player = player
	_hands = [left, right]
	_body = body


func _process(delta: float) -> void:
	if _hands.size() != 2:
		return
	var in_menu: bool = menu_has_mouse.call()
	var stick: Vector2 = Vector2.ZERO if in_menu else _hands[0].get_vector2(&"primary")
	var pushed: Vector2 = stick  # the thumb's own push: the run follows it, not the body's catch-up
	if _body != null:
		_body.stick = stick
		if not in_menu:
			stick = (stick + _body.chase).limit_length(1.0)  # the body walking under the head
		_hold_to_recenter(delta)
	var wanted: Dictionary = {}
	for entry: Array in BUTTONS:
		var held: bool = _hands[entry[1]].is_button_pressed(entry[0])
		wanted[entry[2]] = bool(wanted.get(entry[2], false)) or held
	wanted[JOY_BUTTON_LEFT_STICK] = _run(wanted[JOY_BUTTON_LEFT_STICK], pushed)
	for button: JoyButton in wanted:
		var down: bool = wanted[button] and (not in_menu or BUTTONS_IN_MENUS.has(button))
		if down != bool(_buttons_down.get(button, false)):
			_buttons_down[button] = down
			_send_button(button, down)

	_send_axis(JOY_AXIS_LEFT_X, stick.x)
	_send_axis(JOY_AXIS_LEFT_Y, -stick.y)  # OpenXR: up is +y; a pad: up is -y
	_send_axis(JOY_AXIS_TRIGGER_LEFT, 0.0 if in_menu else _hands[0].get_float(&"trigger"))
	_send_axis(JOY_AXIS_TRIGGER_RIGHT, 0.0 if in_menu else _hands[1].get_float(&"trigger"))
	if not in_menu:
		_snap_turn(_hands[1].get_vector2(&"primary").x)


## A long press of the right stick recentres the view, once per press, hands free.
func _hold_to_recenter(delta: float) -> void:
	if not _hands[1].is_button_pressed(&"primary_click") or _player.get("_owner_carrying") == true:
		_recenter_held = 0.0
		return
	if _recenter_held < 0.0:
		return
	_recenter_held += delta
	if _recenter_held >= RECENTER_HOLD_S:
		_recenter_held = -1.0
		_body.recenter(_body.on_foot.call())


## The left stick's click as the game gets it: [param clicked] now, or still running since a click while
## [param stick] stays pushed (on foot only: seated, the same button is the horn).
func _run(clicked: bool, stick: Vector2) -> bool:
	var on_foot: bool = _player != null and str(_player.get("_seat_vehicle_uuid")) in ["", "<null>"]
	if not on_foot or stick.length() < RUN_HOLD:
		_running = false
	elif clicked:
		_running = true
	return clicked or _running


## One SNAP_TURN_DEG step each time the right stick is pushed sideways, then back to the centre.
func _snap_turn(x: float) -> void:
	if absf(x) < SNAP_REARM:
		_snap_armed = true
		return
	if not _snap_armed or absf(x) < SNAP_PUSH or _player == null:
		return
	_snap_armed = false
	# PlayerClient turns the body by mouse_motion.x * camera_sensitivity rad, to the left when positive.
	var turn := deg_to_rad(SNAP_TURN_DEG) * (-signf(x))
	var sensitivity: float = _player.get("camera_sensitivity")
	var motion: Vector2 = _player.get("mouse_motion")
	_player.set("mouse_motion", motion + Vector2(turn / sensitivity, 0.0))


func _send_button(button: JoyButton, down: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = DEVICE
	event.button_index = button
	event.pressed = down
	event.pressure = 1.0 if down else 0.0
	Input.parse_input_event(event)


func _send_axis(axis: JoyAxis, value: float) -> void:
	var last: float = _axes_sent.get(axis, 0.0)
	if value == last or (value != 0.0 and absf(value - last) < AXIS_EPSILON):
		return  # a value back to exactly 0 is always sent: the stick let go
	_axes_sent[axis] = value
	var event := InputEventJoypadMotion.new()
	event.device = DEVICE
	event.axis = axis
	event.axis_value = value
	Input.parse_input_event(event)


## Let go of everything (leaving VR's control: the rig freed with the player).
func _exit_tree() -> void:
	for button: JoyButton in _buttons_down:
		if _buttons_down[button]:
			_send_button(button, false)
	_buttons_down.clear()
	for axis: JoyAxis in _axes_sent:
		if _axes_sent[axis] != 0.0:
			_send_axis(axis, 0.0)
