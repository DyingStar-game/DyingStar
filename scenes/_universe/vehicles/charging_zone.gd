class_name ChargingZone
extends Area3D
## A place where batteries charge — the hook for the garage's charging bay (to be placed and wired by
## the level, see the empty function below). Not used in any scene yet.
##
## What is ready: VehicleBattery.charge(delta) charges a battery at its spec's rate for its current
## level, slow bands of the sizing sheet included (empty to full in 504 s for a T1), clamps at full,
## publishes the new charge and returns the energy taken in. A charger only has to call it.

## Charging only runs on the server: the charge is server-authoritative and replicated from there.
func _physics_process(delta: float) -> void:
	if GameOrchestrator.is_server():
		_charge_batteries(delta)


## TODO(garage): charge the batteries set down in this zone, every server tick. Left empty on purpose
## for the garage's charging bay. Typically: find the VehicleBattery bodies overlapping the zone
## (get_overlapping_bodies(), with monitoring on and the prop layer in the mask), skip the ones
## fitted in a vehicle if only loose batteries charge here, and call battery.charge(delta) on each.
func _charge_batteries(_delta: float) -> void:
	pass
