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
## Each pad's buttons and axes as last seen by poll_pads, by device: what CHANGED is what counts.
static var _seen : Dictionary = {}


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
##
## By what CHANGES, not by what is held: a device can sit with an axis away from zero — a trigger
## that rests at -1 on some drivers, a virtual pad left with a stick off centre — and read as held, it
## kept the HUD on the gamepad for good and named that device's buttons, "Axis 5+" for LT. A button
## going down, or a stick or trigger moving well across, is a player.
static func poll_pads() -> void:
	var used : int = -1
	for device: int in Input.get_connected_joypads():
		var now : PackedFloat32Array = PackedFloat32Array()
		for button: int in range(JOY_BUTTON_SDL_MAX):
			now.append(1.0 if Input.is_joy_button_pressed(device, button as JoyButton) else 0.0)
		for axis: int in range(JOY_AXIS_SDL_MAX):
			now.append(Input.get_joy_axis(device, axis as JoyAxis))
		var before : PackedFloat32Array = _seen.get(device, now)
		_seen[device] = now
		if used < 0 and moved(before, now):
			used = device
	if used >= 0:
		_use_pad(used)


## Has a pad gone from [param before] to [param now] (buttons, then axes, as poll_pads lists them) by a
## player's hand: a button down, or an axis moved by more than STICK_WAKE.
static func moved(before: PackedFloat32Array, now: PackedFloat32Array) -> bool:
	for i: int in range(mini(before.size(), now.size())):
		if i < JOY_BUTTON_SDL_MAX:
			if now[i] > 0.5 and before[i] < 0.5:
				return true
		elif absf(now[i] - before[i]) >= STICK_WAKE:
			return true
	return false


## The family of the pad the player is most likely holding: the one last used, or else the first one
## plugged in that names itself a pad (a virtual device or a flight stick can come first). None does:
## the Xbox layout, the common one — "Button 1" for a pad not yet touched read as a fault.
static func likely_family() -> Family:
	if last == Kind.GAMEPAD:
		return family
	for device: int in Input.get_connected_joypads():
		var found : Family = family_of(Input.get_joy_name(device), Input.is_joy_known(device))
		if found != Family.GENERIC:
			return found
	return Family.XBOX


static func _use_pad(device: int) -> void:
	last = Kind.GAMEPAD
	pointer = false
	# Asked of a pad that is there: an event from one just unplugged (or made up by a test) has no
	# name to read, and would turn every button into a number.
	if Input.get_connected_joypads().has(device):
		family = family_of(Input.get_joy_name(device), Input.is_joy_known(device))


## The family of a gamepad named [param joy_name] (Input.get_joy_name), [param known] to Godot's
## mapping table or not.
##
## A pad Godot's table does not know by name is still read by its name: an XInput pad on Windows can
## come up unknown, and naming its shoulder buttons "Button 10 / 11" read as broken. Only a device
## whose name says nothing of a pad (a flight stick, a wheel) is numbered.
static func family_of(joy_name: String, known: bool) -> Family:
	var name : String = joy_name.to_lower()
	for word: String in ["playstation", "dualshock", "dualsense", "ps3", "ps4", "ps5", "sony"]:
		if name.contains(word):
			return Family.PLAYSTATION
	for word: String in ["nintendo", "switch", "joy-con", "joycon"]:
		if name.contains(word):
			return Family.NINTENDO
	if known:
		return Family.XBOX
	for word: String in ["xbox", "xinput", "controller", "gamepad", "game pad", "pad"]:
		if name.contains(word):
			return Family.XBOX
	return Family.GENERIC


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
