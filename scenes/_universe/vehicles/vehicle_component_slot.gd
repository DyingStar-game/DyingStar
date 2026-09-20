@tool
class_name VehicleComponentSlot
extends Marker3D

## A bay on a vehicle where a component is bolted in — designer-placed in Godot, like a VehicleSeat
## or a VehicleDoorHandle. Drop one per hatch, aim it where the part should sit and name the hatch
## that guards it. The Vehicle finds its own bays by type, so there is no per-vehicle wiring and a
## new chassis just adds nodes.
##
## A bay does NOT decide what goes in it. The four hatches on the truck are four identical boxes,
## so typing them here would freeze game design into a scene and make the node name (which is the
## key the network table is written with) a claim about its contents. How many engines a chassis
## will run is the CHASSIS's business — see Vehicle.refuse_reason() and max_engines.
##
## It is a Marker3D, NOT an Area3D, because nothing here has to detect anything. A player fitting a
## part is aiming with the carry placement ray, which already resolves a world point; the vehicle
## then picks the nearest free bay to that point. A marker gives the editor gizmo for free and
## costs nothing at runtime — no broad-phase entry, no monitoring pass, nothing for the Area3D
## monitoring check to rule on. The node's own transform IS the mount.
##
## Deliberately NOT parented under the hatch mesh it belongs to. Those meshes carry a non-uniform
## scale (0.175, 0.225, 0.325); Jolt handles a non-uniformly scaled shape badly, and a body
## reparented under one would inherit it. Bays are direct children of the vehicle, exactly like
## SeatDriver and Handle_FL.

## Hatch guarding this bay: the door_id of a VehicleDoorHandle on the same vehicle. Empty means
## open access. Same idea, and the same spelling, as VehicleSeat.door_id.
@export var door_id: String = ""
## How near the drop point has to land (m) for this bay to claim the part.
@export var snap_range: float = 0.5

## Server-authoritative occupant, by uuid. "" = free. On a replica it is mirrored from the
## vehicle's replicated `components` table.
var occupant_uuid: String = ""
## The component node itself, so the vehicle can pin it and hand it back when it comes out.
var occupant: Node = null

## The Vehicle that owns this bay (a bay sits directly under the vehicle in the scene).
func vehicle() -> Node:
	var n: Node = get_parent()
	while n != null and not (n is Vehicle):
		n = n.get_parent()
	return n

func is_free() -> bool:
	return occupant_uuid == "" and occupant == null

## What is fitted here, for the HUD: the part's name, or "free".
func occupant_name() -> String:
	if occupant != null and occupant.has_method("part_name"):
		return str(occupant.part_name())
	return "free"

## Hold [param part] in this bay and return its pose in the vehicle's frame.
##
## What it means to SIT in a bay belongs to the bay, and it is needed in three places that would
## otherwise each spell it out: fitting a part by hand, picking one back up out of the database at
## boot, and mirroring the replicated table on a client. The three used to say the same six lines
## and could drift apart in silence — and the one that drifts is the client, where the part simply
## falls out of the truck while the server holds it pinned.
##
## Frozen KINEMATIC (a STATIC frozen body gets its world transform rewritten every physics frame
## instead of riding its parent), excepted from the vehicle's own collision so it cannot shove the
## truck it is bolted into, and seated ON the bay rather than left wherever it happened to be — a
## fitted part is at its bay by definition, and a freshly spawned one has usually fallen a little
## before anyone gets to it.
func seat(part: Node) -> Transform3D:
	var veh: Node = vehicle()
	part.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	part.freeze = true
	if veh != null:
		veh.add_collision_exception_with(part)
		(part as Node3D).transform = veh.global_transform.affine_inverse() * global_transform
	occupant = part
	occupant_uuid = str(part.uuid) if "uuid" in part else ""
	return (part as Node3D).transform

## Undo seat(): hand the part back loose and dynamic, and leave the bay free. Returns the part.
func release() -> Node:
	var part: Node = occupant
	occupant = null
	occupant_uuid = ""
	if part == null or not is_instance_valid(part):
		return null
	var veh: Node = vehicle()
	if veh != null:
		veh.remove_collision_exception_with(part)
	part.freeze = false
	part.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	return part
