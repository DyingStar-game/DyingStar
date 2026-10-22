class_name PlayerLocation
extends RefCounted

## Where a body IS, spelled the way the services spell it — the client's twin of the server's
## [method GameServer.mission_place_of] and [method GameServer.social_presence_location], which share
## this frame on purpose. One answer for anything that has to record a place: a point of interest, a
## presence, a mission zone.
##
## The frame is the BODY'S OWN, never the universe: a place is `{system, scene, position}` where
## `position` is measured in the frame of the body named by `scene`, so
##
##   • on a body (`scene` = "tarsis_3"): `planet.to_local(where)`, metres from that planet's centre,
##     in ITS OWN rotating frame — a spot on the ground stays on the ground;
##   • in open space (`scene` = "space"): the system frame, the parent there being the system itself.
##
## Why not one universe-wide frame: a planet both ORBITS and SPINS. Its node position is rewritten
## from the Kepler elements on the client every tick, and its basis from the daily turn, so a place
## stored as an absolute triple describes a spot the terrain has long since left — it is stale the
## moment it is written, and wrong by more every second after. A body-local place cannot drift: the
## frame travels with the body, and [method Node3D.to_local] is the SAME arithmetic on the client
## (which spins and orbits) and on the server (which places every body at the origin of its own
## physics world with an identity basis, so to_local is the identity there) — the two sides agree on
## the number without ever exchanging a pose.
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
## prefix and the presence payload's scene), and `position` in metres FROM THAT BODY.
static func presence_of(node: Node3D) -> Dictionary:
	if node == null:
		return {"system": "", "scene": "space", "position": Vector3.ZERO}
	var planet := Planet.of(node)
	if planet == null:
		# Nothing to be relative to but the system, whose frame is the universe one.
		return {"system": "", "scene": "space", "position": node.global_position}
	return {
		"system": SystemScenes.system_of(body_key_of(planet)),
		"scene": body_key_of(planet),
		"position": planet.to_local(node.global_position),
	}


## The body's stable key: PlanetData.planet_name when it has one, the node's name otherwise. This
## is the string the whole project agrees on (see PlanetRegistry).
static func body_key_of(planet: Planet) -> String:
	if planet == null:
		return ""
	if planet.planet_data != null and planet.planet_data.planet_name != "":
		return planet.planet_data.planet_name
	return str(planet.name)


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
