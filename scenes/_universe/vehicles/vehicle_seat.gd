@tool
class_name VehicleSeat
extends Area3D

## A seat on a vehicle: LOOK at it and press E to sit there. Drop one VehicleSeat per place on a
## vehicle scene, fit its CollisionShape3D to the seat itself (cushion and back, inside the cab) and
## position its SitPoint marker (where the occupant sits; for the driver, the eye point too).
##
## A look-at target like a door handle, on the `interactable` layer the player's InteractRay scans —
## not a zone you walk into. It used to be a box beside the cab: whoever stood in it boarded, the
## seat they were looking at or not, two overlapping boxes picked one at random, and the server took
## the client's word for it. Now you board the seat you see, through its open door (a shut door's
## handle box covers it and takes the aim first), and the server re-checks reach and sight
## (PlayerServer "enter_vehicle", REACH_M and aim_point).
##
## The Vehicle discovers its seats automatically (group "vehicle_seat") — no signal wiring and
## no per-vehicle code: future vehicles just add VehicleSeat nodes matching their layout.

enum Role {DRIVER, PASSENGER}

## Farthest the eye may be from the seat (m) for the server to let a player sit: the InteractRay's
## 3 m, plus a metre for the client being a step ahead of the server.
const REACH_M := 4.0

## DRIVER controls the vehicle (drive input + HUD). PASSENGER just rides along.
@export var role: Role = Role.PASSENGER
## Where the occupant sits (and, for the driver, the camera eye point). Falls back to the
## seat node's own transform if left empty.
@export var sit_point: Marker3D
## Door that gates this seat: its door_id (a VehicleDoorHandle's door_id, e.g. "front_l_door"). When
## set, the player must OPEN that door before E can board this seat. Leave empty to board directly.
@export var door_id: String = ""

## Server-authoritative occupant (a player's client_uuid). "" = free.
var occupant_uuid: String = ""
## The occupant's player node, kept so the vehicle can tell when a player vanished (disconnect)
## and free the seat. occupant_mass is what that player added to the truck, to subtract back.
var occupant: Node = null
var occupant_mass: float = 0.0

func _ready() -> void:
	add_to_group("vehicle_seat")
	add_to_group("interactable")  # look-at + E target via the InteractRay, like a door handle
	# PASSIVE look-at target: it never runs an overlap pass of its own (monitoring off), it is only
	# found by the player's InteractRay, which scans the `interactable` layer. Not the zone layer any
	# more: the player's AreaDetector must not take it for a box to stand in.
	monitoring = false
	monitorable = true
	collision_layer = 1 << (Globals.LAYER_INTERACTABLE - 1)
	collision_mask = 0

func is_free() -> bool:
	return occupant_uuid == ""

func is_driver_seat() -> bool:
	return role == Role.DRIVER

## World transform where the occupant sits (eye point for the driver). Uses the exported
## sit_point if set, else a child Marker3D named "SitPoint" (robust if the editor drops the
## export), else the seat node itself.
func sit_transform() -> Transform3D:
	if sit_point != null:
		return sit_point.global_transform
	var sp := get_node_or_null("SitPoint")
	if sp != null:
		return (sp as Node3D).global_transform
	return global_transform

## The Vehicle that owns this seat (the seat is placed under the vehicle in the scene).
func vehicle() -> Node:
	return get_parent()


## The point the server checks reach and sight to: the middle of the seat's box, else the seat node.
func aim_point() -> Vector3:
	for child in get_children():
		if child is CollisionShape3D:
			return (child as Node3D).global_position
	return global_position


## May an eye at [param eye] sit here: within REACH_M of the seat's aim point.
func within_reach(eye: Vector3) -> bool:
	return eye.distance_to(aim_point()) <= REACH_M
