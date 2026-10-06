class_name DoorWind
extends RefCounted
## The wind on an open vehicle door: what slams a cab door shut once the truck picks up speed.
##
## The air meets the open leaf like a flat plate: a pressure of q = 1/2 rho v2 (the dynamic pressure,
## rho from the planet's atmosphere at the vehicle's altitude), over the leaf's area as the flow sees
## it — area x sin(opening angle) — with a flat plate's drag coefficient. That force acts at the
## middle of the leaf, half its width from the hinge. When its torque beats what the door check (the
## strap that holds a door open) can take, the door goes.
##
## Simplifications, named: still air (the only wind is the vehicle's own speed); the plate's
## coefficient taken constant whatever the angle; no gust, no lee of the cab. Static so the numbers
## can be checked without a vehicle.

## Drag coefficient of a flat plate square to the flow.
const PLATE_DRAG := 1.2
## A door whose door_id ends with this catches the wind unless its handle says otherwise: a vehicle's
## doors are named "<where>_door" (front_l_door), its hatches and lids otherwise (hatch_fl).
const DOOR_SUFFIX := "_door"


## Does the door [param door_id] catch the wind when its handle leaves it to the default: a door, not a
## hatch. A future vehicle whose doors follow the naming gets the wind with nothing to set.
static func by_default(door_id: String) -> bool:
	return door_id.ends_with(DOOR_SUFFIX)


## The leaf of a door from the box of its mesh [param aabb] (in the door's own frame) and its
## [param hinge] axis: Vector2(area m2, width m). The leaf's height runs along the hinge, its width is
## its larger other side (the thinnest is its thickness).
static func leaf_of(aabb: AABB, hinge: Vector3) -> Vector2:
	var size : Vector3 = aabb.size.abs()
	var h : Vector3 = hinge.normalized().abs()
	var height : float = size.dot(h)
	var width : float = maxf(size.x * (1.0 - h.x), maxf(size.y * (1.0 - h.y), size.z * (1.0 - h.z)))
	return Vector2(height * width, width)


## The box of every mesh under [param door] (itself included), in the door's own frame: what the door
## looks like whatever angle it stands open at. Walks the local transforms, so it needs no scene tree.
static func mesh_aabb(door: Node3D) -> AABB:
	var meshes : Array[Node] = door.find_children("*", "MeshInstance3D", true, false)
	if door is MeshInstance3D:
		meshes.append(door)
	var out := AABB()
	var first := true
	for node: Node in meshes:
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		var to_door := Transform3D.IDENTITY
		var walk : Node = mesh_node
		while walk != door and walk is Node3D:
			to_door = (walk as Node3D).transform * to_door
			walk = walk.get_parent()
		var box : AABB = to_door * mesh_node.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


## Torque (N.m) the relative wind puts on an open door: [param air_density] (kg/m3), the speed along
## the direction that shuts it [param speed_ms] (m/s), the leaf's [param area_m2] and
## [param width_m] (hinge to free edge), open at [param open_deg].
static func torque_nm(air_density: float, speed_ms: float, area_m2: float, width_m: float,
		open_deg: float) -> float:
	if speed_ms <= 0.0:
		return 0.0
	var dynamic_pressure : float = 0.5 * air_density * speed_ms * speed_ms
	var facing : float = area_m2 * absf(sin(deg_to_rad(open_deg)))
	return dynamic_pressure * PLATE_DRAG * facing * width_m * 0.5


## The speed (km/h) at which that torque reaches [param hold_nm]: the door shuts above it. INF when
## the wind can never do it (no air, no area).
static func shutting_speed_kmh(air_density: float, area_m2: float, width_m: float, open_deg: float,
		hold_nm: float) -> float:
	var per_q : float = PLATE_DRAG * area_m2 * absf(sin(deg_to_rad(open_deg))) * width_m * 0.5
	if air_density <= 0.0 or per_q <= 0.0:
		return INF
	return sqrt(2.0 * hold_nm / (per_q * air_density)) * 3.6
