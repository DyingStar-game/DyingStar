class_name RepairPrompt
extends Interactable

## CLIENT: the prompt a broken screen that takes no click is repaired from (services ADR 0020): a wall
## screen is only looked at, so "Diagnose" is offered on the action key when the player aims at it, in
## place of the button the other machines' screens show. Made by MachineBreakdown while the screen is
## broken, in the screen's frame (facing +Z).

## How far the zone stands out of the wall (m): the crosshair meets it before the wall.
const DEPTH_M := 0.12

var _breakdown: MachineBreakdown = null


## The prompt of [param breakdown]'s screen, [param size_m] wide and high.
func setup(breakdown: MachineBreakdown, size_m: Vector2) -> void:
	_breakdown = breakdown
	label = "%%MACHINE_DIAGNOSE_PROMPT"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(size_m.x, 0.2), maxf(size_m.y, 0.2), DEPTH_M)
	shape.shape = box
	shape.position.z = DEPTH_M * 0.5
	add_child(shape)


## Offer the prompt, or not: not while the repair is on the screen, which then takes the crosshair.
func set_offered(on: bool) -> void:
	collision_layer = 1 << (Globals.LAYER_INTERACTABLE - 1) if on else 0


func interact(_interactor: Node = null):
	if is_instance_valid(_breakdown):
		MachineRepair.open_for(_breakdown)
