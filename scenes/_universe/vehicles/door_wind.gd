class_name DoorWind
extends RefCounted
## The wind on an open vehicle door: what slams a cab door shut once the truck picks up speed, or when
## a gust (a dust wall's front) catches a door left open on a parked truck.
##
## The air on the leaf is the weather's wind at the vehicle minus the vehicle's own velocity (both in
## the vehicle's frame). It meets the open leaf like a flat plate: a pressure of q = 1/2 rho v2 (the
## dynamic pressure, rho from the planet's atmosphere at the vehicle's altitude), over the leaf's area
## as the flow sees it, with a flat plate's drag coefficient. Only the part of the flow that hits the
## leaf's OUTER face pushes it shut: air coming from the front of a front-hinged door, or from its own
## side of the vehicle (push_direction); air from the other side or from behind holds it open, and
## shuts nothing. That force acts at the middle of the leaf, half its width from the hinge. When its
## torque beats what the door check (the strap that holds a door open) can take, the door goes.
##
## Simplifications, named: the plate's coefficient taken constant whatever the angle; the wind read at
## the vehicle's centre, the same for all its doors; no lee of the cab (a door on the sheltered side
## gets the full wind); the dashboard's shutting speed (shutting_speed_kmh) is still the still-air one.
## Static so the numbers can be checked without a vehicle.

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


## Torque (N.m) the relative wind puts on an open door when it comes straight from the direction of
## travel that shuts it: [param air_density] (kg/m3), its speed [param speed_ms] (m/s), the leaf's
## [param area_m2] and [param width_m] (hinge to free edge), open at [param open_deg].
static func torque_nm(air_density: float, speed_ms: float, area_m2: float, width_m: float,
		open_deg: float) -> float:
	if speed_ms <= 0.0:
		return 0.0
	var dynamic_pressure : float = 0.5 * air_density * speed_ms * speed_ms
	var facing : float = area_m2 * absf(sin(deg_to_rad(open_deg)))
	return dynamic_pressure * PLATE_DRAG * facing * width_m * 0.5


## The direction (vehicle frame, unit) the AIR must move in to push an open door shut: the flow that
## hits the leaf's outer face square on. [param shut_travel] is the handle's wind_shut_travel (driving
## that way shuts it: the air then moves the opposite way), [param hinge] the door's hinge axis,
## [param door_pos] where the door is in the vehicle's frame (its handle), which tells its side, and
## [param open_deg] how far it stands open. Wide open, the leaf faces the oncoming air of travel; nearly
## shut, it faces sideways, and only a wind from its own side pushes it home. With no side to tell (a
## door on the centre line) the travel part alone, which is the still-air model.
static func push_direction(shut_travel: Vector3, hinge: Vector3, door_pos: Vector3, open_deg: float) -> Vector3:
	var travel : Vector3 = shut_travel.normalized()
	var axis : Vector3 = hinge.normalized() if hinge.length_squared() > 0.000001 else Vector3.UP
	var open_rad : float = deg_to_rad(open_deg)
	var head_on : Vector3 = -travel * absf(sin(open_rad))
	var outward : Vector3 = door_pos - travel * door_pos.dot(travel) - axis * door_pos.dot(axis)
	if outward.length_squared() < 0.000001:
		return head_on
	return head_on - outward.normalized() * absf(cos(open_rad))


## Torque (N.m) the air [param air_ms] (m/s, relative to the vehicle: weather wind minus the vehicle's
## velocity, vehicle frame) puts on an open door towards shut: [param air_density] (kg/m3), the
## [param push_dir] from push_direction, the leaf's [param area_m2] and [param width_m]. The leaf is a
## plate: the flow's pressure over the area it sees, |air| x (air . push_dir) per unit area. Zero when
## the air comes from the side that holds the door open. For air moving straight back at v, it is
## torque_nm at the same speed.
static func torque_from_air_nm(air_density: float, air_ms: Vector3, push_dir: Vector3, area_m2: float,
		width_m: float) -> float:
	var along : float = air_ms.dot(push_dir)
	if along <= 0.0 or air_density <= 0.0:
		return 0.0
	return 0.5 * air_density * air_ms.length() * along * PLATE_DRAG * area_m2 * width_m * 0.5


## The speed (km/h) at which torque_nm reaches [param hold_nm], in still air: the door shuts above it
## (a head wind lowers it, a tail wind raises it). INF when
## the wind can never do it (no air, no area).
static func shutting_speed_kmh(air_density: float, area_m2: float, width_m: float, open_deg: float,
		hold_nm: float) -> float:
	var per_q : float = PLATE_DRAG * area_m2 * absf(sin(deg_to_rad(open_deg))) * width_m * 0.5
	if air_density <= 0.0 or per_q <= 0.0:
		return INF
	return sqrt(2.0 * hold_nm / (per_q * air_density)) * 3.6
