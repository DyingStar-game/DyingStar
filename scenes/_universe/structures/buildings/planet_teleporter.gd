extends Node3D

## Dev fixture: pads that drop you at the atmosphere test sites.
##
## Keeps the pads' TRIGGERS in step with their visibility, because the two are independent in Godot
## and silently diverge. Hiding a node does not stop its Area3D being detected: the pads sit at
## monitoring = false and are found by the PLAYER's own AreaDetector (the project's pattern -- one
## monitor, the player), so a hidden pad stays armed and teleports anyone who walks through it.
##
## With this, the single `visible` checkbox in the inspector arms and disarms the whole rig, which is
## what anyone toggling it expects. Off by default: these are for testing the sky, not level content.


func _ready() -> void:
	visibility_changed.connect(_apply_visibility)
	_apply_visibility()


## Arm the pads only while the rig is visible.
func _apply_visibility() -> void:
	for area in get_children():
		if area is Area3D:
			(area as Area3D).monitorable = visible
