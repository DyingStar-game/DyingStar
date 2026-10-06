@tool
class_name VehicleDoorHandle
extends Area3D

## A door handle on a vehicle — designer-placed in Godot (like a VehicleSeat) and editor-adjustable.
## Drop one next to each door, size its CollisionShape3D (the "look here + press E" box on the handle),
## and set door_id to the door's animation prefix in the GLB.
##
## Server-authoritative: the player's interact ray detects the handle by LOOKING at it; pressing `action`
## sends a server action, the server toggles the door and replicates the open/close to everyone. No
## per-vehicle wiring — future vehicles just add VehicleDoorHandle nodes and set door_id.

## Which door this handle opens: the prefix of its Blender animation clips on the vehicle's GLB
## (e.g. "front_l_door" → clips "front_l_door_open" / "front_l_door_close"). A handle with no clip
## still works via the Vehicle's code hinge-swing fallback on the mesh named door_id.
@export var door_id: String = ""
## Fallback swing ONLY (door with no Blender clip): max opening angle of the door, in degrees.
@export var open_angle_deg: float = 75.0
## Reverse the opening: the door swings the other way (fallback), or its clip plays backwards (anim).
@export var reverse: bool = false
## Fallback swing ONLY: the hinge axis of THIS door, in the vehicle's local frame. Leave at zero to
## use the vehicle's door_hinge_axis. A cab door turns about the vertical, a bay hatch usually does
## not, and one axis for the whole vehicle cannot serve both.
@export var hinge_axis: Vector3 = Vector3.ZERO
@export_group("Wind")
## Area of the door leaf (m2) the relative wind presses on once it is open. -1 = measured from the
## door's own mesh when its door_id ends with "_door" (a cab door), none otherwise (a hatch: hatch_fl);
## 0 = the wind never shuts this door; a value = that area. See DoorWind.
@export_range(-1.0, 5.0, 0.05) var wind_area_m2: float = -1.0
## The direction of travel, in the vehicle's frame, whose airflow pushes this door SHUT: a cab door
## hinged at its front edge is shut by driving forward, Vector3(0, 0, -1).
@export var wind_shut_travel: Vector3 = Vector3.FORWARD
## Width of the leaf (m), hinge to free edge: the wind's push acts at half of it. -1 = measured from
## the door's mesh, like the area.
@export_range(-1.0, 3.0, 0.05) var wind_width_m: float = -1.0
## Torque (N.m) the door check — the strap that holds a door open — takes before it gives way. Higher
## = the door stays open to a higher speed (twice the hold, 1.41 times the speed).
@export_range(0.0, 500.0, 1.0) var wind_hold_nm: float = 25.0
@export_group("")

## The collision box (a child CollisionShape3D) looked at from OUTSIDE, on foot — placed proud of the
## exterior door surface. Assigned in the inspector; used for the server line-of-sight check. Optional:
## unassigned = no sightline gate (the door just opens when looked at).
@export var outdoor_shape: CollisionShape3D
## The collision box looked at from INSIDE, while seated — placed on the interior side of the door.
@export var indoor_shape: CollisionShape3D

func _ready() -> void:
	add_to_group("vehicle_door_handle")
	add_to_group("interactable")  # generic: look-at + E targets via the InteractRay (scans `interactable`)
	# PASSIVE look-at target on the `interactable` layer so the player's look-at ray (collide_with_areas)
	# detects it. monitorable-only: it never runs its own overlap pass. The carry placement/LOS ray
	# scans solids only (not `interactable`), so a handle never blocks carry aim.
	monitoring = false
	monitorable = true
	collision_layer = 1 << (Globals.LAYER_INTERACTABLE - 1)  # interactable (InteractRay), NOT zone (seats)
	collision_mask = 0

## The Vehicle that owns this handle (placed somewhere under the vehicle in the scene).
func vehicle() -> Node:
	var n: Node = get_parent()
	while n != null and not (n is Vehicle):
		n = n.get_parent()
	return n

## The collision box to sightline-check for a player on the given side: seated (inside) → the indoor
## box, on foot (outside) → the outdoor box. Falls back to whichever is assigned, so a half-configured
## handle still works; null only when neither is set (then the caller skips the sightline gate).
func side_shape(inside: bool) -> CollisionShape3D:
	if inside:
		return indoor_shape if indoor_shape != null else outdoor_shape
	return outdoor_shape if outdoor_shape != null else indoor_shape

## Which side's box the player is looking at, from the ray's hit point: the nearer of the two assigned
## boxes → "outdoor" / "indoor" (or "" if none assigned). Lets the interaction require the box that
## matches where the player is, so aiming at the box on the far side (that you can't reach) doesn't count.
func aimed_side(hit_point: Vector3) -> String:
	var d_out: float = hit_point.distance_to(outdoor_shape.global_position) if outdoor_shape != null else INF
	var d_in: float = hit_point.distance_to(indoor_shape.global_position) if indoor_shape != null else INF
	if d_out == INF and d_in == INF:
		return ""
	return "indoor" if d_in < d_out else "outdoor"
