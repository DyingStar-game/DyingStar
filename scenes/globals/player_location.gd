class_name PlayerLocation
extends RefCounted

## Where a body IS, spelled the way the services spell it — the client's twin of the server's
## social_presence_location. One answer for anything that has to record a place: a point of
## interest, a presence, a mission zone.
##
## The frame is the services' own (see the inventory OpenAPI on a POI's x/y/z): true universe
## coordinates, the body's spawn-time orbital position plus the node's position inside its world —
## the planet sits at its world's origin with an identity basis, so a standing player's global
## position is already "relative to the body", and the orbital offset is what makes it absolute.
##
## Static and pure of state: it only walks the tree and the network's body registry, so a test can
## stand up a body of its own and ask.

## The caller's own body in the tree, or null (headless, not spawned yet, a test standing up no
## player). Untyped on purpose: the agent holds it untyped too, to keep the dependency loose.
static func local_player() -> Node3D:
	var agent = NetworkOrchestrator.network_agent
	if agent == null or not "player_entity" in agent:
		return null
	var entity: Variant = agent.player_entity
	if entity is Node3D and is_instance_valid(entity):
		return entity as Node3D
	return null


## The caller's own place, as a service would store it: `system` ("" off-world), `scene` ("space"
## off-world, else the body key — the same string as PlanetData.planet_name, the `<key>_poi.json`
## prefix and the presence payload's scene), and `position` in metres.
static func presence_of(node: Node3D) -> Dictionary:
	if node == null:
		return {"system": "", "scene": "space", "position": Vector3.ZERO}
	var planet := Planet.of(node)
	if planet == null:
		return {"system": "", "scene": "space", "position": node.global_position}
	var body_key: String = body_key_of(planet)
	return {
		"system": SystemScenes.system_of(body_key),
		"scene": body_key,
		"position": orbital_abs(planet) + node.global_position,
	}


## The body's stable key: PlanetData.planet_name when it has one, the node's name otherwise. This
## is the string the whole project agrees on (see PlanetRegistry).
static func body_key_of(planet: Planet) -> String:
	if planet == null:
		return ""
	if planet.planet_data != null and planet.planet_data.planet_name != "":
		return planet.planet_data.planet_name
	return str(planet.name)


## The body's SPAWN-TIME absolute orbital position, walking up its parents. Spawn-time, not
## "where it is now": the frame Horizon's zones and the services' stored coordinates live in — the
## same rule the server follows (_planet_orbital_abs). A parent not yet resolved stops the walk
## rather than inventing an offset.
static func orbital_abs(body: Planet) -> Vector3:
	if body == null:
		return Vector3.ZERO
	var acc: Vector3 = body.orbital_position
	var cur: Planet = body
	var guard: int = 0
	while cur.orbital_parent_uuid != "" and guard < 8:  # a cyclic record must not hang the walk
		guard += 1
		var parent := find_by_uuid(cur.orbital_parent_uuid)
		if parent == null:
			return acc  # parent not spawned here — the offset it would have added is unknown
		acc += parent.orbital_position
		cur = parent
	return acc


## The [Planet] the network registry holds under [param uuid], or null.
static func find_by_uuid(uuid: String) -> Planet:
	if uuid == "":
		return null
	var agent = NetworkOrchestrator.network_agent
	if agent == null or not "props_list" in agent or not agent.props_list.has("planets"):
		return null
	var body: Variant = agent.props_list["planets"].get(uuid)
	if body is Planet and is_instance_valid(body):
		return body as Planet
	return null
