class_name VillageArrival
extends RefCounted

## Where a trip to a VILLAGE lands. SERVER side, like TeleportGround: an authority decision.
##
## A village is listed by its centre (its POI's longitude and latitude), and that is where a trip
## used to land: on the terrain under the layout's origin, whatever stands there. In the mining
## villages the cargo depot does -- a hall ninety-five metres long, laid across the origin -- so every
## traveller arrived inside it, their truck with them (playtest 2026-11-20).
##
## Every village and city layout has a teleporter cabin of its own. A trip to a village now ends
## there: the one who pressed lands [constant FRONT_M] in front of its door, and what travelled along
## -- the truck parked in the departure cabin, the other passengers -- is set down in the arrival cabin
## as it stood in the departure one (Teleporter._move_riders), which is the one place guaranteed to
## hold it: the two cabins are the same scene.
##
## Nothing is added to the layouts for this: the cabin is read from the layout scene's own data,
## without instantiating it. A layout with no cabin, or a destination that is not a village's centre,
## is left to TeleportGround as before.

## The cabin a layout is searched for.
const CABIN_SCENE: String = "res://scenes/_universe/structures/buildings/teleporter/teleporter.tscn"
## From the cabin's origin to its doorway, along its own -Z (teleporter.tscn: Blockout / Doorway).
const DOOR_M: float = 6.0
## How far in front of that door the traveller lands: clear of the cabin, short of what faces it (the
## mining village's guard post stands 8.6 m from the door).
const FRONT_M: float = 4.0
## A destination this close to a village's centre (m) IS that village: what the catalogue hands out is
## the centre itself, to the rounding of a payload. Further out it is a point somebody typed in.
const CENTRE_REACH_M: float = 30.0

## layout scene path -> its cabin's Transform3D in the layout's frame, or null when it has none.
static var _cabins: Dictionary = {}


## Where a trip to [param dest] on [param planet] lands when it is a village's centre:
## {dest: the same destination moved in front of the village's cabin, cabin: that cabin's Transform3D
## in the planet's frame}. {} for anything else -- a typed-in point, a village without a cabin, a body
## whose terrain knows no village.
static func resolve(planet: Planet, dest: TeleportDestination) -> Dictionary:
	if planet == null or planet.planet_terrain == null or planet.planet_data == null:
		return {}
	if dest.height_mode != TeleportDestination.Height.GROUND:
		return {}  # an orbit over a village is not a visit to it
	var dir: Vector3 = HEALPix.lonlat2vec(dest.lon, dest.lat)
	var zone: Dictionary = zone_at(planet.planet_terrain.village_zones(), dir, planet.planet_data.radius)
	if zone.is_empty():
		return {}
	var cabin: Variant = cabin_in_planet(zone)
	if not cabin is Transform3D:
		return {}
	var front: Vector2 = HEALPix.vec2lonlat(landing_of(cabin).normalized())
	var moved := TeleportDestination.new(dest.label, dest.planet_name, front.x, front.y, dest.height,
			dest.height_mode, dest.kind, dest.detail)
	return {"dest": moved, "cabin": cabin}


## The village of [param zones] (PlanetTerrain.village_zones) whose centre [param dir] points at, on
## a body [param radius_m] across; {} when it points at none. The nearest, should two overlap.
static func zone_at(zones: Array, dir: Vector3, radius_m: float) -> Dictionary:
	var best: Dictionary = {}
	var best_m: float = CENTRE_REACH_M
	for entry: Variant in zones:
		var zone: Dictionary = entry
		var away_m: float = dir.angle_to((zone["local_pos"] as Vector3).normalized()) * radius_m
		if away_m <= best_m:
			best_m = away_m
			best = zone
	return best


## The frame a village's items are placed in, in its planet's frame: +Y along the radial, the
## heading of [param basis] kept. The very construction of PoiVillages._stand_on_ground, so that a
## village still asleep -- stored with whatever rotation its data has -- answers as it will once awake.
static func frame_of(local_pos: Vector3, basis: Basis) -> Transform3D:
	var up: Vector3 = local_pos.normalized()
	var z_axis: Vector3 = basis.z - up * basis.z.dot(up)
	if z_axis.length_squared() < 1e-9:
		z_axis = up.cross(Vector3.RIGHT)
		if z_axis.length_squared() < 1e-9:
			z_axis = up.cross(Vector3.BACK)
	z_axis = z_axis.normalized()
	var x_axis: Vector3 = up.cross(z_axis).normalized()
	z_axis = x_axis.cross(up).normalized()
	return Transform3D(Basis(x_axis, up, z_axis), local_pos)


## The cabin of the village [param zone] ({local_pos, basis, layout}), in its planet's frame; null
## when its layout has none.
static func cabin_in_planet(zone: Dictionary) -> Variant:
	var cabin: Variant = cabin_of(str(zone.get("layout", "")))
	if not cabin is Transform3D:
		return null
	return frame_of(zone["local_pos"], zone["basis"]) * (cabin as Transform3D)


## Where the traveller lands for a cabin standing at [param cabin]: in front of its door, in the
## frame [param cabin] is given in.
static func landing_of(cabin: Transform3D) -> Vector3:
	return cabin * Vector3(0.0, 0.0, -(DOOR_M + FRONT_M))


## The teleporter cabin of the layout [param scene_path] (res:// or not), in the layout's frame; null
## when the scene cannot be read or holds none. The first one, in a city that has several. Read from
## the scene's own data, not from an instance: a layout is a hundred buildings.
static func cabin_of(scene_path: String) -> Variant:
	if scene_path == "":
		return null
	var path: String = scene_path if scene_path.begins_with("res://") else "res://" + scene_path
	if _cabins.has(path):
		return _cabins[path]
	var found: Variant = null
	var packed := load(path) as PackedScene if ResourceLoader.exists(path) else null
	if packed != null:
		found = _cabin_in(packed.get_state())
	_cabins[path] = found
	return found


## The transform of the first node of [param state] that instances the cabin directly under the root.
static func _cabin_in(state: SceneState) -> Variant:
	for node: int in state.get_node_count():
		var instance: PackedScene = state.get_node_instance(node)
		if instance == null or instance.resource_path != CABIN_SCENE:
			continue
		if state.get_node_path(node, true) != NodePath("."):
			continue  # inside another item, or tidied in a folder: its transform is not in the layout's frame
		for property: int in state.get_node_property_count(node):
			if state.get_node_property_name(node, property) == &"transform":
				return state.get_node_property_value(node, property)
		return Transform3D.IDENTITY  # at the layout's origin: the scene stores no transform then
	return null
