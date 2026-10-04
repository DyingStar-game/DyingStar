class_name VehicleEnergy
extends RefCounted
## Where a vehicle's energy comes from: the batteries in its bays, ONE at a time (GDD 6.1). The
## vehicle draws on the first battery that still holds a charge, in bay order, and moves on to the
## next when it runs dry; bay order is the same on the server and on every replica, so everyone
## agrees which battery is in use without it being replicated.
##
## What it costs: the torque the motors are actually asked for, at the battery's discharge
## coefficient (VehicleBatterySpec.draw_w) — not the speed. A slope, a load or a bad road ask for
## more torque for the same distance, and so for more energy. Nothing else draws: the head lights and
## the dashboard work for free, as long as some energy is left.

var _bays: VehicleComponentBays


func _init(bays: VehicleComponentBays) -> void:
	_bays = bays


## The batteries fitted, in bay order.
##
## A bay can still name a battery that is gone: the server frees a fitted part as a prop of its own
## when it leaves the zone, while the truck itself is still there for a few frames. Testing `is` on
## that freed node is a script error, and in a release build the function then returns a null
## where its caller expects an Array — the server crashed iterating it (SIGSEGV in active(), from
## the dashboard, each time a driven truck crossed a server border).
func batteries() -> Array[VehicleBattery]:
	var out: Array[VehicleBattery] = []
	for s in _bays.all():
		if is_instance_valid(s.occupant) and s.occupant is VehicleBattery:
			out.append(s.occupant)
	return out


## The battery in use: the first one, in bay order, that still holds a charge. Null when none does.
func active() -> VehicleBattery:
	for b in batteries():
		if not b.is_empty():
			return b
	return null


func has_energy() -> bool:
	return active() != null


## Draw what [param torque_nm] of motor torque costs over [param delta] seconds, from the battery in
## use, then the next ones if it runs out mid-tick (server). Returns the energy that could not be
## supplied (J): above 0, the batteries are all empty.
func draw_for_torque(torque_nm: float, delta: float) -> float:
	var wanted: float = 0.0
	var battery: VehicleBattery = active()
	if battery != null:
		wanted = (battery.spec as VehicleBatterySpec).draw_w(torque_nm) * delta
	while wanted > 0.0 and battery != null:
		wanted -= battery.draw(wanted)
		battery = active()
	return wanted


## Each battery for the dashboard, in bay order: {"fraction": 0..1, "charge_j", "capacity_j",
## "active": in use}.
func levels() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var in_use: VehicleBattery = active()
	for b in batteries():
		out.append({"fraction": b.fraction(), "charge_j": b.charge_j, "capacity_j": b.capacity_j(),
				"active": b == in_use})
	return out
