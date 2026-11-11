class_name TruckElevatorRamp
extends AnimatableBody3D
## The front ramp of the truck elevator's platform, hinged on the deck's front edge: folded up (a barrier across the
## way out) while the lift runs and at the top (its front faces the shaft there), laid down onto the landing when it
## stops at a level or at the bottom. Driven by the lift's replicated state
## (VehicleLift.is_moving), so the server's collision and every client's ramp move alike. One box of collision, which
## turns with it.

## Angle (deg) of the ramp folded up: -90 = upright, its tip straight above the hinge.
@export_range(-120.0, 0.0, 1.0, "suffix:deg") var folded_deg: float = -90.0
## Angle (deg) of the ramp laid down: positive tips it down onto the landing's floor. Higher = a steeper ramp.
@export_range(0.0, 30.0, 0.5, "suffix:deg") var laid_deg: float = 5.0
## Time (s) the ramp takes to fold up or lay down. Lower = snappier.
@export_range(0.1, 10.0, 0.1, "suffix:s") var fold_time_s: float = 1.5

var _lift: VehicleLift = null


func _ready() -> void:
	sync_to_physics = false
	_lift = _find_lift()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_lift):
		_lift = _find_lift()
		if _lift == null:
			return
	var folded := _lift.is_moving() or _lift.at_top()
	var target := deg_to_rad(folded_deg if folded else laid_deg)
	var step := absf(deg_to_rad(laid_deg - folded_deg)) / maxf(fold_time_s, 0.01) * delta
	rotation.x = move_toward(rotation.x, target, step)


## The lift this ramp's platform belongs to (platform -> platform system -> lift).
func _find_lift() -> VehicleLift:
	var at := get_parent()
	while at != null and not at is VehicleLift:
		at = at.get_parent()
	return at as VehicleLift
