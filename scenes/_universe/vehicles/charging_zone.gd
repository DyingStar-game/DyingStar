class_name ChargingZone
extends Area3D
## A place where batteries charge: the garage's charging bay (garage.tscn) for now.
##
## What is ready: VehicleBattery.charge(delta) charges a battery at its spec's rate for its current
## level, slow bands of the sizing sheet included (empty to full in 504 s for a T1), clamps at full,
## publishes the new charge and returns the energy taken in. A charger only has to call it.
##
## Scene setup: a CollisionShape3D child, monitoring on, the prop layer (4, value 8) in collision_mask.

## Charging only runs on the server: the charge is server-authoritative and replicated from there.
## A client has nothing to detect, so the zone is switched off there (no overlap tracking per tick).
func _ready() -> void:
	if not GameOrchestrator.is_server():
		monitoring = false
		set_physics_process(false)


func _physics_process(delta: float) -> void:
	if GameOrchestrator.is_server():
		_charge_batteries(delta)


## Charge every LOOSE battery lying in the zone, every server tick. One fitted in a vehicle's bay is
## left alone: a truck parked here does not charge (its batteries come out and go on the floor).
func _charge_batteries(delta: float) -> void:
	for body in get_overlapping_bodies():
		if body is VehicleBattery and not (body as VehicleBattery).is_fitted():
			(body as VehicleBattery).charge(delta)
