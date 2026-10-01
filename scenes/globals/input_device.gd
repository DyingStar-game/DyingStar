class_name InputDevice
extends RefCounted
## Keyboard and mouse, or a gamepad: which one an input belongs to, which one the player is using,
## and the one rule for changing an action's binding on one of them without touching the other.
##
## An action holds a binding per device: Jump is Space AND the A button. Rebinding the key must leave
## the button alone, and the HUD must name the one the player has in their hands — "[E] Open" for a
## player on the gamepad reads as a key they cannot press.
##
## Fed with EVERY window event from Globals (Window.window_input, which fires before any node's
## _input), like AltGr. Static, so there is one answer.

enum Kind { KEYBOARD_MOUSE, GAMEPAD }
## How a gamepad's buttons are printed on it. A known pad (SDL's mapping table) lays its buttons out
## like an Xbox one whatever it is; what changes is what is printed. A device Godot does not know —
## a flight stick, a wheel — has numbered buttons and axes, and is named by number.
enum Family { XBOX, PLAYSTATION, NINTENDO, GENERIC }

## How far a stick or a trigger must move to count as the player taking the gamepad: a resting stick
## drifts, and a pad lying on the desk must not take the HUD away from the keyboard.
const STICK_WAKE : float = 0.5
## How far the mouse must move, in pixels in one event, to count as the player taking it back.
const MOUSE_WAKE : float = 4.0
## The keys of a binding per device in user://inputs.map.
const KEYS : Dictionary = {Kind.KEYBOARD_MOUSE: "km", Kind.GAMEPAD: "pad"}

static var last : Kind = Kind.KEYBOARD_MOUSE
## The last input came from the mouse, not from a key or the pad: a menu then shows no focus frame.
static var pointer : bool = true
static var family : Family = Family.XBOX


static func feed(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		if (event as InputEventJoypadButton).pressed:
			_use_pad(event.device)
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) >= STICK_WAKE:
			_use_pad(event.device)
	elif event is InputEventKey:
		last = Kind.KEYBOARD_MOUSE
		pointer = false
	elif event is InputEventMouseButton:
		last = Kind.KEYBOARD_MOUSE
		pointer = true
	elif event is InputEventMouseMotion:
		if (event as InputEventMouseMotion).relative.length() >= MOUSE_WAKE:
			last = Kind.KEYBOARD_MOUSE
			pointer = true


## Look at the gamepads themselves, once a frame: a button down, a stick or a trigger pushed means the
## player is on the pad. The window's event stream (feed) never carries gamepad events — they reach
## the game through Input, not through the window — so that alone left the pad never noticed: the HUD
## kept naming keys and the menus kept their tab hints hidden. Called by Globals.
static func poll_pads() -> void:
	for device: int in Input.get_connected_joypads():
		for button: int in range(JOY_BUTTON_SDL_MAX):
			if Input.is_joy_button_pressed(device, button as JoyButton):
				_use_pad(device)
				return
		for axis: int in range(JOY_AXIS_SDL_MAX):
			if absf(Input.get_joy_axis(device, axis as JoyAxis)) >= STICK_WAKE:
				_use_pad(device)
				return


static func _use_pad(device: int) -> void:
	last = Kind.GAMEPAD
	pointer = false
	# Asked of a pad that is there: an event from one just unplugged (or made up by a test) has no
	# name to read, and would turn every button into a number.
	if Input.get_connected_joypads().has(device):
		family = family_of(Input.get_joy_name(device), Input.is_joy_known(device))


## The family of a gamepad named [param joy_name] (Input.get_joy_name), [param known] to Godot's
## mapping table or not.
static func family_of(joy_name: String, known: bool) -> Family:
	if not known:
		return Family.GENERIC
	var name : String = joy_name.to_lower()
	for word: String in ["playstation", "dualshock", "dualsense", "ps3", "ps4", "ps5", "sony"]:
		if name.contains(word):
			return Family.PLAYSTATION
	for word: String in ["nintendo", "switch", "joy-con", "joycon"]:
		if name.contains(word):
			return Family.NINTENDO
	return Family.XBOX


## Which device [param event] is a binding of, or -1 for neither (a mouse motion, a touch).
static func kind_of(event: InputEvent) -> int:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return Kind.GAMEPAD
	if event is InputEventKey or event is InputEventMouseButton:
		return Kind.KEYBOARD_MOUSE
	return -1


## The bindings of [param action] on [param kind], in the order the InputMap holds them.
static func bindings(action: StringName, kind: Kind) -> Array[InputEvent]:
	var out : Array[InputEvent] = []
	if not InputMap.has_action(action):
		return out
	for event: InputEvent in InputMap.action_get_events(action):
		if kind_of(event) == kind:
			out.append(event)
	return out


## Bind [param action] to [param event] on [param event]'s device, replacing what that device had and
## nothing else: a key replaces the keys and mouse buttons, a pad button the pad's buttons and axes.
static func rebind(action: StringName, event: InputEvent) -> void:
	var kind : int = kind_of(event)
	if kind < 0 or not InputMap.has_action(action):
		return
	for old: InputEvent in bindings(action, kind):
		InputMap.action_erase_event(action, old)
	InputMap.action_add_event(action, event)
