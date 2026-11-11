class_name MissionSites
extends RefCounted

## Where the player's missions send them, on the star chart (F2): the zone of an inspection (the mission
## service's `visit` objective, a place 5 to 40 km from a village), drawn as a square with its name -- a
## place nobody could find from "23 km from F0001" alone.
##
## Like the home (HomeLocation): the chart only draws the MapMarkers this client has, so the zones hang
## under their planet as markers of their own. The list is read from the mission service when the chart
## opens and when a mission is taken (refresh); the chart hangs it before it draws (ensure).

## Name of the node the zones hang from, under their planet.
const ANCHOR_NAME := &"MissionSites"
## Their pictogram and colour: ARES Security's, see-through -- the ground shows under a zone.
const ICON := preload("res://assets/textures/map_markers/radar.png")
const FILL_ALPHA := 0.5
## The pictogram, half the others' size: it stands over the zone, and at full size it covers a zone of
## 1 km from 20 km up -- the player saw a pictogram and no zone (playtest 2026-11-11).
const ICON_SCALE := 0.5
## A zone's radius when its mission does not say (m).
const DEFAULT_RADIUS_M := 1500.0
## A zone's height on the chart (m): a flat mark.
const HEIGHT_M := 1.0
## Seen from this high above the ground (m): a zone is found from far.
const MAX_VIEW_M := 100000.0
## Missions read at once: a player holds a handful.
const LIST_LIMIT := 50

## The zones of the player's active missions: [{"name", "scene", "poi", "position": Vector3, "radius":
## float}], "poi" the id of the zone's point of interest ("" when it has none).
static var _sites: Array = []
## Bumped each time _sites changes: a planet whose markers were built from an older list rebuilds them.
static var _version: int = 0


## The zones the objectives of a mission ([param objectives], the mission service's) send a player to:
## the `visit` ones not done yet whose place has a position. Pure.
static func sites_of(objectives: Variant) -> Array:
	var sites: Array = []
	if not (objectives is Array):
		return sites
	for objective: Variant in objectives:
		if not (objective is Dictionary) or str(objective.get("type", "")) != "visit":
			continue
		if str(objective.get("status", "")) == "completed":
			continue
		var place: Variant = objective.get("locationTo")
		var at: Variant = place.get("position") if place is Dictionary else null
		if not (at is Dictionary) or not (at.get("x") is float or at.get("x") is int):
			continue
		var radius := float(place.get("radiusM", 0.0)) if (place.get("radiusM") is float or place.get("radiusM") is int) else 0.0
		sites.append({
			"name": str(place.get("name", "")),
			"scene": str(place.get("scene", "")),
			"poi": str(place.get("poiUuid", "")) if place.get("poiUuid") != null else "",
			"position": Vector3(float(at.get("x")), float(at.get("y", 0.0)), float(at.get("z", 0.0))),
			"radius": radius if radius > 0.0 else DEFAULT_RADIUS_M,
		})
	return sites


## CLIENT: read the zones of the player's active missions from the mission service. An unanswered call
## keeps what was known.
static func refresh() -> void:
	var listed: Dictionary = await PlayerServices.my_missions("active", LIST_LIMIT)
	if not bool(listed.get("ok", false)):
		return
	var sites: Array = []
	for row: Dictionary in ServiceTypes.mission_rows(listed.get("data")):
		var mission: Variant = row.get("mission")
		# Only the missions that send somewhere are asked for in full (the list has no objectives).
		if not (mission is Dictionary) or str(mission.get("category", "")) != "exploration":
			continue
		var detail: Dictionary = await PlayerServices.mission_get(str(mission.get("id", "")))
		var data: Variant = detail.get("data")
		if bool(detail.get("ok", false)) and data is Dictionary:
			sites.append_array(sites_of(data.get("objectives")))
	_sites = sites
	_version += 1


## The known zone whose point of interest is [param poi_id], {} when there is none: a zone is only its
## holder's to see, so the chart cannot ask the inventory service where it is.
static func site_of_poi(poi_id: String) -> Dictionary:
	if poi_id == "":
		return {}
	for site: Dictionary in _sites:
		if str(site.get("poi", "")) == poi_id:
			return site
	return {}


## CLIENT: hang the known zones of [param planet] under it, once per list. Called by the chart before
## it draws.
static func ensure(planet: Planet) -> void:
	if planet == null or planet.planet_data == null:
		return
	var anchor := planet.get_node_or_null(NodePath(ANCHOR_NAME)) as Node3D
	if anchor != null and int(anchor.get_meta(&"version", -1)) == _version:
		return
	if anchor == null:
		anchor = Node3D.new()
		anchor.name = ANCHOR_NAME
		planet.add_child(anchor)
	anchor.set_meta(&"version", _version)
	for child: Node in anchor.get_children():
		anchor.remove_child(child)
		child.queue_free()
	var here := str(planet.planet_data.planet_name)
	for site: Dictionary in _sites:
		if site["scene"] == "" or site["scene"] == here:
			anchor.add_child(_zone(site))


## The node of [param site] in its planet's frame: flat on the ground, its marker a square as wide as
## the zone.
static func _zone(site: Dictionary) -> Node3D:
	var zone := Node3D.new()
	zone.transform = ground_frame(site["position"])
	var marker := MapMarker.new()
	marker.label = str(site["name"])  # a place's name, the same in every language
	marker.icon = ICON
	marker.importance = 1
	marker.max_view_m = MAX_VIEW_M
	var colour: Color = AresBrand.colour(AresBrand.Subsidiary.SECURITY)
	marker.colour = Color(colour, FILL_ALPHA)
	marker.icon_tint = colour
	marker.icon_scale = ICON_SCALE
	var width: float = 2.0 * float(site["radius"])
	marker.footprint_size = Vector3(width, HEIGHT_M, width)
	marker.groupable = false
	marker.on_top = true
	zone.add_child(marker)
	return zone


## The frame of a point of a planet ([param position], from its centre): there, its Y straight up.
## Identity at the centre. Pure.
static func ground_frame(position: Vector3) -> Transform3D:
	if position.is_zero_approx():
		return Transform3D.IDENTITY
	var up := position.normalized()
	var across := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	return Transform3D(Basis(across, up, across.cross(up)), position)
