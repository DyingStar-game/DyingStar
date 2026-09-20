class_name VehicleComponentBays
extends RefCounted

## The component bays of ONE vehicle: which bays exist, what sits in them, what the chassis will
## take, and what all that adds up to. Pure bookkeeping — it owns no scene nodes, it reads the
## vehicle's own VehicleComponentSlot children. The Vehicle holds one and asks it questions.
##
## Same split as VehiclePowertrain: keeping this out of vehicle.gd leaves that file about the BODY
## rather than about what is bolted inside it. (vehicle.gd is already 3000 lines and at gdlint's
## public-method ceiling, which is the mechanical way of being told the same thing.)
##
## A BAY does not decide what goes into it — the four hatches on the truck are four identical boxes.
## The CHASSIS does, through the limits handed in here. Typing a kind into each bay would freeze
## game design into a scene, and would make a bay's node name a claim about its contents; that name
## is the key the replicated and persisted table is written with, so it has to describe WHERE the
## bay is and nothing else.

## Fitted or removed something. The vehicle listens and rebuilds its drive model and its mass —
## a signal rather than a call back into vehicle.gd, which is already at gdlint's public-method
## ceiling and has no business growing a component API.
signal changed

## The vehicle these bays belong to. Untyped to avoid a cyclic class dependency with Vehicle.
var vehicle: Node = null

## Fitted part -> its pose in the vehicle's frame, re-asserted every physics frame. Deliberately
## SEPARATE from the bed's _locked_cargo_local: a bolted-in part is not cargo, it must not count
## towards the payload, and it must not be thrown out by the rollover spill. Sharing that dict
## would have given the pinning for free and cost the two rules that matter.
var _pinned: Dictionary = {}

## The sizing model for what is fitted. Lives here rather than on the Vehicle because the answer
## depends on the BAYS; the chassis only contributes its fixed numbers, which are read on rebuild.
var _drive_spec := VehicleDriveSpec.new()

## What the chassis will run, by component kind. -1 = no limit. Filled from the vehicle's exports.
var max_engines: int = -1

func _init(owner_vehicle: Node) -> void:
	vehicle = owner_vehicle


## Every bay on the vehicle, in scene order. Found by TYPE among the vehicle's own descendants
## rather than through a global group: a bay only ever belongs to one vehicle, and this works
## before the vehicle is in the tree. Same reasoning as Vehicle._door_handle().
func all() -> Array:
	var out: Array = []
	if vehicle == null:
		return out
	for n in vehicle.find_children("*", "VehicleComponentSlot", true, false):
		out.append(n)
	return out


## A bay by its node name — the key the network table is written with, so it must stay stable
## across a restart. Null when there is no such bay.
func find(slot_name: String) -> Node:
	for s in all():
		if str(s.name) == slot_name:
			return s
	return null


## How many components of this kind the chassis will run. -1 = no limit. SINGLE point of extension:
## a battery or tank limit is one more branch here and nothing else moves.
func limit_for(kind: int) -> int:
	if kind == VehicleComponentSpec.Kind.ENGINE:
		return max_engines
	return -1


## How many components of that kind are fitted right now.
func fitted_count(kind: int) -> int:
	var n: int = 0
	for s in all():
		if s.occupant != null and s.occupant.spec != null and s.occupant.spec.kind == kind:
			n += 1
	return n


## Why the chassis will not take another one of these, or "" when it will. A REASON rather than a
## bool: a refusal the player cannot read is indistinguishable from a bug.
func refuse_reason(spec: VehicleComponentSpec) -> String:
	if spec == null:
		return "Not a vehicle part"
	var limit: int = limit_for(spec.kind)
	if limit >= 0 and fitted_count(spec.kind) >= limit:
		return "This chassis takes %d %s" % [limit, spec.display_name]
	return ""


## The engines actually driving the vehicle: those bolted into bays, plus the ones the chassis
## leaves the works with. Both count the same way — a factory engine is not a special case, it is
## simply one nobody has taken out yet.
func engines() -> Array[VehicleEngineSpec]:
	var out: Array[VehicleEngineSpec] = []
	if vehicle != null:
		for e in vehicle.factory_engines:
			if e != null:
				out.append(e)
	for s in all():
		if s.occupant != null and s.occupant.spec is VehicleEngineSpec:
			out.append(s.occupant.spec)
	return out


## Mass (kg) of everything bolted in. Part of the VEHICLE's own weight, never of its payload: a
## bolted-in engine is not cargo, and counting it as such would eat the load limiter's budget and
## could immobilise the truck for being overloaded by its own engines.
func total_mass() -> float:
	var total: float = 0.0
	for s in all():
		if s.occupant != null and s.occupant.spec != null:
			total += s.occupant.spec.mass_kg
	return total


## Who is in which bay, as {bay name: component uuid}. DERIVED on demand and never stored, exactly
## like Vehicle._seat_occupancy_now() — a cached copy is a copy that can disagree.
func occupancy() -> Dictionary:
	var occ: Dictionary = {}
	for s in all():
		occ[str(s.name)] = s.occupant_uuid
	return occ


## Bolt a part into a bay. Returns "" on success, or the reason it was refused — a refusal the
## player cannot read is indistinguishable from a bug.
##
## Server only. The pose, the freeze and the reparent follow Vehicle._lock_cargo: the part keeps
## its collision LAYER (so it can still be aimed at to take it back out) and only stops fighting
## the truck body, and it goes through server_parent_change so PropSync does not fire a delete on
## the way (a raw reparent() makes a prop vanish from Horizon).
func install(slot: Node, part: Node) -> String:
	if slot == null or part == null:
		return "Nothing to fit"
	if not slot.is_free():
		return "That bay is taken"
	if slot.door_id != "" and not vehicle.is_door_open(slot.door_id):
		return "Open the hatch first"
	var spec = part.spec if "spec" in part else null
	var refused: String = refuse_reason(spec)
	if refused != "":
		return refused
	part.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	part.freeze = true
	vehicle.add_collision_exception_with(part)
	if part.has_method("server_parent_change"):
		part.server_parent_change(vehicle)
	else:
		part.reparent(vehicle)
	part.transform = vehicle.global_transform.affine_inverse() * slot.global_transform
	part.slot_id = str(slot.name)
	slot.occupant = part
	slot.occupant_uuid = str(part.uuid)
	_pinned[part] = part.transform
	part.send_properties_to_client(str(vehicle.uuid))
	changed.emit()
	return ""


## Take the part out of a bay and hand it back, loose and dynamic again. Returns it, or null.
func remove(slot: Node) -> Node:
	if slot == null or slot.occupant == null:
		return null
	var part: Node = slot.occupant
	_pinned.erase(part)
	slot.occupant = null
	slot.occupant_uuid = ""
	if is_instance_valid(part):
		part.slot_id = ""
		vehicle.remove_collision_exception_with(part)
		part.freeze = false
		part.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	changed.emit()
	return part


## Re-assert every fitted part's pose. A KINEMATIC child drifts under a parent that moves, so this
## runs each physics frame alongside the bed's own pinning.
func pin() -> void:
	for part in _pinned.keys():
		if is_instance_valid(part):
			(part as Node3D).transform = _pinned[part]
		else:
			_pinned.erase(part)


## The free bay nearest a world point that would take `spec`, or null. Used to decide whether a
## part being put down lands in a bay rather than in the bed — the two overlap on this truck, two
## of its four hatches sit inside the cargo loading zone.
func slot_for_point(world_point: Vector3, spec: VehicleComponentSpec) -> Node:
	var best: Node = null
	var best_d: float = INF
	for s in all():
		if not s.is_free():
			continue
		if s.door_id != "" and not vehicle.is_door_open(s.door_id):
			continue
		var d: float = world_point.distance_to(s.global_position)
		if d <= s.snap_range and d < best_d:
			best_d = d
			best = s
	if best != null and refuse_reason(spec) != "":
		return null
	return best


## Re-establish the link between a bay and the part that came back inside it after a restart.
##
## Persistence returns the part parented to the vehicle with the right pose, but nothing says which
## BAY it belongs to — so it is neither frozen nor pinned, and it falls straight through the truck.
## slot_id is what closes that gap: the part carries the name of its bay, so the answer is looked up
## rather than guessed. (The shelf has to work the same thing out geometrically, every reload, with
## a tolerance and a retry window. Naming it is a function we get to not write.)
##
## Nothing is MOVED here: the pose came back with the prop and is authoritative. Returns how many
## were rebound, so the caller can stop asking.
func rebind() -> int:
	if vehicle == null:
		return 0
	var done: int = 0
	for child in vehicle.get_children():
		if not (child is VehicleComponent):
			continue
		var sid: String = str(child.slot_id)
		if sid == "":
			continue
		var slot: Node = find(sid)
		if slot == null or not slot.is_free():
			continue
		child.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		child.freeze = true
		vehicle.add_collision_exception_with(child)
		child.set_meta("component_slot_ref", slot)  # so taking it back out frees the bay
		slot.occupant = child
		slot.occupant_uuid = str(child.uuid)
		_pinned[child] = child.transform
		done += 1
	if done > 0:
		changed.emit()
	return done


## The drive model for what is bolted in right now. Never null. Rebuilt on every change (see the
## `changed` signal), so reading it is free — gravity alone is refreshed, to follow the planet the
## vehicle is standing on.
func drive_spec() -> VehicleDriveSpec:
	if vehicle != null:
		_drive_spec.gravity = vehicle.gravity_magnitude
	return _drive_spec


## Recompute the model from the chassis numbers plus what is fitted. Called when the engine list
## changes, never per frame: _sync_powertrain runs at 60 Hz and walking the bays there would land
## in PropNet.prof_vehicle_usec across every truck at once.
func rebuild_drive_spec() -> void:
	if vehicle == null:
		return
	max_engines = vehicle.max_engines
	_drive_spec.motors = engines()
	_drive_spec.wheel_radius = vehicle.wheel_radius
	_drive_spec.pump_efficiency = vehicle.pump_efficiency
	_drive_spec.hydraulic_efficiency = vehicle.hydraulic_efficiency
	_drive_spec.torque_factor = vehicle.torque_factor
	_drive_spec.drag_coefficient = vehicle.drag_coefficient
	_drive_spec.frontal_area = vehicle.frontal_area_m2
	_drive_spec.rolling_coefficient = vehicle.rolling_coefficient
	_drive_spec.rolling_factor = vehicle.rolling_factor
	_drive_spec.air_density = vehicle.air_density
	_drive_spec.gravity = vehicle.gravity_magnitude
