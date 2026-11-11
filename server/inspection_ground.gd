class_name InspectionGround
extends RefCounted

## SERVER: lays the simulator's inspection sites on the ground (services ADR 0019). The simulator makes a
## site 5 to 40 km from a village at the village's altitude, for it knows no relief; the game server has
## the terrain, so it answers where the ground is under each. A site gets its missions only after.
##
## Asked by MissionHeartbeat, now and then: sites are made once per village, there is rarely one to lay.

## Lay every site the simulator has not laid yet that stands on one of [param planets]. [param call] is
## the simulator's internal API: func(method, path, body) -> {ok, data | error}. Returns how many were
## laid.
static func lay(call: Callable, planets: Array) -> int:
	var listed: Dictionary = await call.call(HTTPClient.METHOD_GET, "/inspection-sites/ungrounded", null)
	var data: Variant = listed.get("data")
	if not bool(listed.get("ok", false)) or not (data is Dictionary) or not (data.get("items") is Array):
		return 0
	var laid := 0
	for item: Variant in data.get("items"):
		var ground: Variant = ground_of(item, planets)
		if ground == null:
			continue
		var at: Vector3 = ground
		var answer: Dictionary = await call.call(HTTPClient.METHOD_PUT,
				"/inspection-sites/%s/ground" % str(item.get("id", "")).uri_encode(), {"x": at.x, "y": at.y, "z": at.z})
		if bool(answer.get("ok", false)):
			laid += 1
		else:
			push_warning("[InspectionGround] site %s not laid: %s" % [str(item.get("id", "")), str(answer.get("error", "ERROR"))])
	return laid


## Where the ground is under the site [param item] ({id, scene, position: {x, y, z}}), in its planet's
## frame; null when it stands on none of [param planets] or says no place.
static func ground_of(item: Variant, planets: Array) -> Variant:
	var at: Variant = item.get("position") if item is Dictionary else null
	if not (at is Dictionary):
		return null
	for coordinate: String in ["x", "y", "z"]:
		if not (at.get(coordinate) is float or at.get(coordinate) is int):
			return null
	var position := Vector3(float(at["x"]), float(at["y"]), float(at["z"]))
	for node: Variant in planets:
		var planet := node as Planet
		if planet != null and planet.planet_data != null and str(planet.planet_data.planet_name) == str(item.get("scene", "")):
			return on_ground(position, planet.planet_data.carved_surface_dist)
	return null


## [param position] (from a planet's centre) brought to the ground under it: the same direction, at the
## distance [param surface_dist] gives for it (func(direction) -> metres from the centre). Pure.
static func on_ground(position: Vector3, surface_dist: Callable) -> Vector3:
	if position.is_zero_approx():
		return position
	var direction := position.normalized()
	return direction * float(surface_dist.call(direction))
