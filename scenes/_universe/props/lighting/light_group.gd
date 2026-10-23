class_name LightGroup
extends Node3D
## The lights of a building as one switch: a Photocell under the group drives every lamp below it
## (anything with set_lit, a NeonSign or a LedPanel; a bare Light3D is shown or hidden), sub-groups
## included. One photocell per building, not one per lamp.


## Switch every lamp under the group. [param animate] is passed on to the lamps that take it.
func set_lit(on: bool, animate: bool = false) -> void:
	_switch_under(self, on, animate)


## Switch [param target]: a lamp with set_lit (a NeonSign, a LedPanel, a group) is asked to, a bare Light3D
## is shown or hidden, and anything else is walked for the lamps below it. Shared with whatever else
## switches lamps it is pointed at (WallSwitch).
static func switch(target: Node, on: bool, animate: bool = false) -> void:
	if target.has_method("set_lit"):
		target.set_lit(on, animate)
	elif target is Light3D:
		(target as Light3D).visible = on
	else:
		_switch_under(target, on, animate)


## Switch every lamp below [param node], walking into the sub-groups (a lamp's own children are its
## parts, not further lamps).
static func _switch_under(node: Node, on: bool, animate: bool) -> void:
	for child: Node in node.get_children():
		if not child is Photocell:
			switch(child, on, animate)
