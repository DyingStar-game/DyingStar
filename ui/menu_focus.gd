class_name MenuFocus
extends RefCounted
## Driving a menu without the mouse: the gamepad's cross or stick, or the keyboard's arrows, move from
## item to item (Godot's own focus navigation), A or Enter presses, B or Escape goes back.
##
## What Godot does not do by itself is START: nothing has the focus when a screen opens, so the first
## arrow or button press goes nowhere. A screen hands that press here, and its first item takes the
## focus instead. With the mouse in hand nothing is given the focus: a focus frame over a menu being
## clicked is noise.

## A window is up over the menu (PadPopup): the bar and the tabs leave the focus and the shoulder
## buttons to it.
static var modal : bool = false


## Is [param event] somebody reaching for the menu without the mouse: a gamepad button, a stick pushed
## (InputDevice.STICK_WAKE), an arrow key or Enter?
static func wants_focus(event: InputEvent) -> bool:
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).pressed
	if event is InputEventJoypadMotion:
		return absf((event as InputEventJoypadMotion).axis_value) >= InputDevice.STICK_WAKE
	if event is InputEventKey and (event as InputEventKey).pressed:
		for action: StringName in [&"ui_up", &"ui_down", &"ui_left", &"ui_right", &"ui_accept"]:
			if event.is_action_pressed(action):
				return true
	return false


## The first item under [param root] that can take the focus and is on screen, or null.
static func first_item(root: Node) -> Control:
	for node: Node in root.find_children("*", "Control", true, false):
		var item := node as Control
		if item.focus_mode != Control.FOCUS_NONE and item.is_visible_in_tree():
			return item
	return null


## Give the focus to [param root]'s first item. False when it has none.
static func take(root: Node) -> bool:
	var item : Control = first_item(root)
	if item == null:
		return false
	item.grab_focus()
	return true


## Every scrolling list under [param root] keeps the focused item in view, so moving down a long page
## with the cross scrolls it.
static func follow(root: Node) -> void:
	for node: Node in root.find_children("*", "ScrollContainer", true, false):
		(node as ScrollContainer).follow_focus = true
