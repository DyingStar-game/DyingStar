class_name HomeLocation
extends RefCounted

## Where the player lives, for the star chart (F2): "My home", seen from anywhere on its planet. Told
## by the buildings (ApartmentPlates), read by the chart (StarMapMarkers): it belongs to neither.
##
## The chart only draws what this client knows of, the objects replicated near the player -- a home
## out of reach would vanish. So the client remembers its apartment the moment it sees it
## (SpawnBuilding._label_plates), in its PLANET's frame (the planet turns, a frame of its own does not
## drift), keeps it in user:// for the next sessions, and hangs a MapMarker of its own at that place
## under the planet. The apartment's own marker steps aside, so the home is drawn once.

## Where the remembered home is kept between sessions, one section per player.
const SAVE_PATH := "user://home_location.cfg"
## Name of the node the home marker hangs from, under its planet.
const ANCHOR_NAME := &"HomeAnchor"
## The middle of a habitat container's floor in its apartment's frame (the apartment's origin is a
## corner): where the marker's footprint is centred.
const APARTMENT_MIDDLE := Vector3(-3.05, 0.0, 1.3)
## A container's footprint (m): x across, z along, y its height.
const FOOTPRINT := Vector3(6.1, 2.6, 2.6)
## The home's colour on the chart: the green of its door plate.
const COLOUR := Color(0.25, 0.85, 0.35, 0.95)
const ICON := preload("res://assets/textures/map_markers/habitat.png")


## CLIENT: [param apartment] is the player's home: remember it (and save it) and mark it on its planet.
static func remember(apartment: Node3D, player_uuid: String) -> void:
	if not apartment.is_inside_tree():
		# The building's state arrives before it is added to the tree: its planet is not above it yet.
		if not apartment.tree_entered.is_connected(remember):
			apartment.tree_entered.connect(remember.bind(apartment, player_uuid), CONNECT_ONE_SHOT)
		return
	var planet: Planet = Planet.of(apartment)
	if planet == null or planet.planet_data == null:
		print("[Home] %s: no planet above it, not marked on the chart" % apartment.get_path())
		return
	var place: Transform3D = LocalFrame.of(apartment, planet) * Transform3D(Basis.IDENTITY, APARTMENT_MIDDLE)
	var planet_name := str(planet.planet_data.planet_name)
	var saved: Dictionary = load_home(player_uuid)
	var known: bool = saved.get("planet", "") == planet_name and (saved["place"] as Transform3D).is_equal_approx(place)
	if known and planet.has_node(NodePath(ANCHOR_NAME)):
		return  # the same home seen again (each change of the building's occupants shows it)
	_save(player_uuid, planet_name, place)
	_anchor(planet, place)
	print("[Home] %s marked on %s at %s" % [apartment.name, planet_name, place.origin])


## CLIENT: hang the remembered home of [param player_uuid] on [param planet] if it is there and not
## hung yet (a new session, a planet built again). Called by the chart before it draws.
static func ensure(planet: Planet, player_uuid: String) -> void:
	if planet == null or planet.planet_data == null or planet.has_node(NodePath(ANCHOR_NAME)):
		return
	var saved: Dictionary = load_home(player_uuid)
	if saved.get("planet", "") == str(planet.planet_data.planet_name):
		_anchor(planet, saved["place"])


## The saved home of [param player_uuid]: {"planet": name, "place": Transform3D in its frame}, or {}.
static func load_home(player_uuid: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if player_uuid == "" or cfg.load(SAVE_PATH) != OK or not cfg.has_section(player_uuid):
		return {}
	var place = cfg.get_value(player_uuid, "place", null)
	if not (place is Transform3D):
		return {}
	return {"planet": str(cfg.get_value(player_uuid, "planet", "")), "place": place}


static func _save(player_uuid: String, planet_name: String, place: Transform3D) -> void:
	if player_uuid == "":
		return
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)  # missing on the first home: starts empty
	cfg.set_value(player_uuid, "planet", planet_name)
	cfg.set_value(player_uuid, "place", place)
	cfg.save(SAVE_PATH)


## The marker node of the home under [param planet], created or moved to [param place].
static func _anchor(planet: Planet, place: Transform3D) -> Node3D:
	var anchor := planet.get_node_or_null(NodePath(ANCHOR_NAME)) as Node3D
	if anchor == null:
		anchor = Node3D.new()
		anchor.name = ANCHOR_NAME
		var marker := MapMarker.new()
		marker.label = "%%MAP_MARKER_MY_HOME"
		marker.icon = ICON
		marker.importance = 1
		marker.max_view_m = 100000.0
		marker.colour = COLOUR
		marker.footprint_size = FOOTPRINT
		anchor.add_child(marker)
		planet.add_child(anchor)
	anchor.transform = place
	return anchor
