class_name PlanetRegistry
extends RefCounted

## Where a celestial body IS, right now — the live counterpart of [SystemScenes], which only knows
## what exists on disk.
##
## Two ways to ask, and they are not interchangeable:
##   [method find_by_name]  — the authoritative registry the network fills (props_list["planets"]).
##                            This is what a server decision must use.
##   [method live_planets]  — the planets in the tree, for anything that has to draw what is loaded.
##
## ⚠️ NEVER look a body up by NODE name. The server renames its planets to Horizon's names
## ("tarsis_3_2" becomes "P3_M2"), so scene-root names only exist on the client and find_child() is
## reliable on neither side. PlanetData.planet_name is the one stable key, and it is the same string
## as the scene basename, the `<key>_poi.json` prefix and the `<key>_chunks` directory.
##
## Static on purpose: it holds nothing, it only knows where to look.


## The live [Planet] whose PlanetData.planet_name is [param planet_name], or null.
##
## Goes through the network registry rather than the tree: that dictionary is what both the server
## and the client treat as the truth about which bodies exist, and it is filled by create_planet.
static func find_by_name(planet_name: String) -> Planet:
	if planet_name == "":
		return null
	var agent = NetworkOrchestrator.network_agent
	if agent == null or not "props_list" in agent or not agent.props_list.has("planets"):
		return null
	for puuid in agent.props_list["planets"]:
		var body := agent.props_list["planets"][puuid] as Planet
		if is_instance_valid(body) and body.planet_data != null \
				and body.planet_data.planet_name == planet_name:
			return body
	return null


## Every [Planet] currently in the tree. Only bodies in GORC range are there, so this answers "what
## is loaded", never "what exists" — for that, read the files ([SystemScenes]).
static func live_planets() -> Array[Planet]:
	var out: Array[Planet] = []
	var universe: Node = NetworkOrchestrator.universe_scene
	if universe == null or not universe.is_inside_tree():
		_walk(universe, out)  # a universe not in the tree yet (a test): nothing is grouped there
		return out
	# From the planets' group: walking the whole universe (a village alone is thousands of nodes, 49 000
	# in all) for the thirty bodies cost the star chart 4.7 ms a frame (playtest 2026-10-21).
	for node: Node in universe.get_tree().get_nodes_in_group(Planet.GROUP):
		if node is Planet and universe.is_ancestor_of(node):
			out.append(node as Planet)
	return out


static func _walk(node: Node, out: Array[Planet]) -> void:
	if node == null:
		return
	for child: Node in node.get_children():
		if child is PlanetTerrain:
			continue  # chunk nodes, never a body
		if child is Planet:
			out.append(child as Planet)
		_walk(child, out)
