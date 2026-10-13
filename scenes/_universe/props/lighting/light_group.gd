class_name LightGroup
extends Node3D
## The lights of a building as one switch: a Photocell under the group drives every lamp below it
## (anything with set_lit, a NeonSign or a LedPanel; a bare Light3D is shown or hidden), sub-groups
## included. One photocell per building, not one per lamp.


## Switch every lamp under the group. [param animate] is passed on to the lamps that take it.
func set_lit(on: bool, animate: bool = false) -> void:
	_switch_under(self, on, animate)


static func _switch_under(node: Node, on: bool, animate: bool) -> void:
	for child: Node in node.get_children():
		if child is Photocell:
			continue
		if child.has_method("set_lit"):
			child.set_lit(on, animate)
		elif child is Light3D:
			(child as Light3D).visible = on
		else:
			_switch_under(child, on, animate)
