@tool
class_name VehicleDoorHandle
extends Area3D

## A door handle on a vehicle — designer-placed in Godot (like a VehicleSeat) and editor-adjustable.
## Drop one next to each door, size its CollisionShape3D (the "look here + press E" box on the handle),
## and set door_id to the door's animation prefix in the GLB.
##
## Server-authoritative: the player's interact ray detects the handle by LOOKING at it; pressing E
## sends a server action, the server toggles the door and replicates the open/close to everyone. No
## per-vehicle wiring — future vehicles just add VehicleDoorHandle nodes and set door_id.

## Which door this handle opens: the prefix of its Blender animation clips on the vehicle's GLB
## (e.g. "Front_l_door" → clips "Front_l_door_open" / "Front_l_door_close"). A handle with no clip
## still works via the Vehicle's code hinge-swing fallback on the mesh named door_id.
@export var door_id: String = ""
## Fallback swing ONLY (door with no Blender clip): max opening angle of the door, in degrees.
@export var open_angle_deg: float = 75.0
## Reverse the opening: the door swings the other way (fallback), or its clip plays backwards (anim).
@export var reverse: bool = false

func _ready() -> void:
	add_to_group("vehicle_door_handle")
	# PASSIVE, on the interact layer (1) so the player's look-at ray (collide_with_areas) detects it.
	# monitorable-only: it never runs its own overlap pass. (NOT on VEHICLE_ZONE_LAYER, which the ray
	# ignores — that layer is for the proximity zones like seats/cargo.)
	monitoring = false
	monitorable = true
	collision_layer = 1
	collision_mask = 0

## The Vehicle that owns this handle (placed somewhere under the vehicle in the scene).
func vehicle() -> Node:
	var n: Node = get_parent()
	while n != null and not (n is Vehicle):
		n = n.get_parent()
	return n
