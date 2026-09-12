class_name TeleportCatalog
extends RefCounted

## What a teleporter can OFFER: systems, bodies, and the places on a body worth going to.
##
## Presentation only, and client-side only. It never decides where anybody lands — it hands out
## longitudes and latitudes, and [TeleportGround] turns the chosen one into a position, on the
## server, against real terrain.
##
## Two sources, and the split matters:
##   POI       — read from `<body>_poi.json`, the QGIS export. ⚠️ There are 27 POI in the whole game
##               and all of them are on tarsis_3; the other eighteen files are empty stubs.
##   DERIVED   — computed for ANY body. Without these, eighteen bodies out of nineteen would offer an
##               empty list and could only be reached by typing coordinates.
##
## The POI file is preferred over the `Area3D` nodes baked into a planet scene even though both exist:
## the nodes are GENERATED from this very file by PlanetTerrain.import_poi_from_json(), so the two
## agree by construction — and reading an 8 KB JSON costs nothing next to loading a planet scene.

const POI_DIR: String = "res://assets/qgis/export"
## How far above the ground a derived or ground-mode destination puts you. Small: enough not to spawn
## inside the terrain, not so much that you fall.
const GROUND_CLEARANCE_M: float = 2.0
## Height of the "low orbit" derived entry, above the reference radius.
const ORBIT_HEIGHT_M: float = 100000.0


static func systems() -> PackedStringArray:
	return SystemScenes.systems()


## The bodies of a system, parents before their moons, each as
## `{ "key": "tarsis_3_1", "label": "Korax - Tarsis III.M1", "is_moon": true }`.
static func bodies(system: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var known: Dictionary = {}
	# body_keys() is sorted, so a parent is always seen before its moons — which is what makes the
	# naming-convention lookup below reliable.
	for key: String in SystemScenes.body_keys(system):
		var props: Dictionary = SystemScenes.body_properties(system, key)
		var parent_key: String = SystemScenes.parent_key_of(key, known)
		known[key] = true
		out.append({
			"key": key,
			"label": SystemScenes.display_name_of(key, props),
			"is_moon": parent_key != "",
		})
	return out


## Everywhere you can go on [param planet_name]: its POI first, then the derived points.
static func destinations(planet_name: String) -> Array[TeleportDestination]:
	var out: Array[TeleportDestination] = []
	out.append_array(poi_destinations(planet_name))
	out.append_array(derived_destinations(planet_name))
	return out


## POI exported from QGIS. Empty — and that is normal, not a failure — for eighteen of the nineteen
## bodies, whose files carry `"count": 0`.
static func poi_destinations(planet_name: String) -> Array[TeleportDestination]:
	var out: Array[TeleportDestination] = []
	var path: String = "%s/%s_poi.json" % [POI_DIR, planet_name]
	if not FileAccess.file_exists(path):
		return out
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("pois")) != TYPE_ARRAY:
		push_warning("[TeleportCatalog] '%s' is not a POI export" % path)
		return out
	for entry in parsed["pois"]:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		# `elevation` is a deliberate override, in metres above sea level; null — which is the case
		# for all 27 today — means "put me on whatever ground is actually there".
		var elevation = entry.get("elevation")
		var mode: TeleportDestination.Height = TeleportDestination.Height.GROUND
		var height: float = GROUND_CLEARANCE_M
		if elevation != null:
			mode = TeleportDestination.Height.SEA
			height = float(elevation) + GROUND_CLEARANCE_M
		out.append(TeleportDestination.new(
				str(entry.get("name", "?")), planet_name,
				float(entry.get("lon", 0.0)), float(entry.get("lat", 0.0)),
				height, mode, TeleportDestination.Kind.POI,
				_poi_detail(entry)))
	return out


## Points every body has, whether anyone has surveyed it or not. Six on the ground plus one in orbit:
## enough to land anywhere in the system on the day a body gets its terrain and nothing else.
##
## ⚠️ No "highest point" / "lowest point" here, tempting as it is: a body's manifest carries elev_min
## and elev_max but NOT where they are, so finding them means sweeping the tiles. Better to offer six
## honest points than one invented one.
static func derived_destinations(planet_name: String) -> Array[TeleportDestination]:
	var out: Array[TeleportDestination] = []
	var ground: Array = [
		["North pole", 0.0, 90.0],
		["South pole", 0.0, -90.0],
		["Equator, lon 0", 0.0, 0.0],
		["Equator, lon 90", 90.0, 0.0],
		["Equator, lon 180", 180.0, 0.0],
		["Equator, lon -90", -90.0, 0.0],
	]
	for spot: Array in ground:
		out.append(TeleportDestination.new(
				str(spot[0]), planet_name, float(spot[1]), float(spot[2]),
				GROUND_CLEARANCE_M, TeleportDestination.Height.GROUND,
				TeleportDestination.Kind.DERIVED, "on the ground"))
	out.append(TeleportDestination.new(
			"Low orbit", planet_name, 0.0, 0.0,
			ORBIT_HEIGHT_M, TeleportDestination.Height.SEA,
			TeleportDestination.Kind.DERIVED, "%d km above sea level" % int(ORBIT_HEIGHT_M / 1000.0)))
	return out


## Case-insensitive substring match over the label AND the detail line, so "mining" finds the villages
## by their type and "Palaka" finds the city by its name. An empty needle keeps everything.
static func filter(list: Array[TeleportDestination], needle: String) -> Array[TeleportDestination]:
	var trimmed: String = needle.strip_edges().to_lower()
	if trimmed == "":
		return list
	var out: Array[TeleportDestination] = []
	for dest: TeleportDestination in list:
		if dest.label.to_lower().contains(trimmed) or dest.detail.to_lower().contains(trimmed):
			out.append(dest)
	return out


static func _poi_detail(entry: Dictionary) -> String:
	var bits: PackedStringArray = PackedStringArray()
	var poi_type: String = str(entry.get("poi_type", ""))
	if poi_type != "":
		bits.append(poi_type)
	var population: int = int(entry.get("population", 0))
	if population > 0:
		bits.append("pop. %d" % population)
	return ", ".join(bits)
