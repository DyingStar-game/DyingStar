@tool
class_name VehicleSeat
extends Area3D

## A seat zone on a vehicle — designer-placed and editor-adjustable, like the mining depot's
## detection box. Drop one VehicleSeat per place on a vehicle scene, size its CollisionShape3D
## (the "press E here" box, e.g. left of the cab for the driver, right for a passenger) and
## position its SitPoint marker (where the occupant sits; for the driver, the eye point too).
##
## The Vehicle discovers its seats automatically (group "vehicle_seat") — no signal wiring and
## no per-vehicle code: future vehicles just add VehicleSeat nodes matching their layout.

enum Role {DRIVER, PASSENGER}

## DRIVER controls the vehicle (drive input + HUD). PASSENGER just rides along.
@export var role: Role = Role.PASSENGER
## Where the occupant sits (and, for the driver, the camera eye point). Falls back to the
## seat node's own transform if left empty.
@export var sit_point: Marker3D
## Door that gates this seat: its door_id (a VehicleDoorHandle's door_id, e.g. "Front_l_door"). When
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
	# PASSIVE zone: the seat no longer MONITORS. A monitoring Area3D runs a full broad-phase
	# overlap pass every physics frame for whatever falls inside it — wasted CPU, and on the
	# server it ran for EVERY seat of EVERY vehicle even though nothing was wired there. Instead
	# the seat is only MONITORABLE, on the dedicated vehicle-zone layer, and the player's own
	# AreaDetector (the single monitor) reports when it walks in. One monitor per player, not one
	# per seat. This makes the detection work identically on client and server.
	monitoring = false
	monitorable = true
	collision_layer = Globals.VEHICLE_ZONE_LAYER
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
