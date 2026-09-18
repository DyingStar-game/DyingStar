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

## The vehicle these bays belong to. Untyped to avoid a cyclic class dependency with Vehicle.
var vehicle: Node = null

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
