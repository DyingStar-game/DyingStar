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
## The POI file is the only list of them on the client: the planet scenes no longer carry POI nodes
## (the villages are networked props now), and reading an 8 KB JSON costs nothing.

const POI_DIR: String = "res://assets/qgis/export"
## The headings that are not a POI type (translation keys), in the list's order with the POI between.
const GROUP_STATIONS: String = "%%TELEPORT_GROUP_STATIONS"
const GROUP_POI: String = "%%TELEPORT_GROUP_POI"
const GROUP_COMPUTED: String = "%%TELEPORT_GROUP_COMPUTED"

## How far above the ground a derived or ground-mode destination puts you. Small: enough not to spawn
## inside the terrain, not so much that you fall.
const GROUND_CLEARANCE_M: float = 2.0
## Height of the "low orbit" derived entry, above the reference radius.
const ORBIT_HEIGHT_M: float = 100000.0


static func systems() -> PackedStringArray:
	return SystemScenes.systems()


## Over this mass (Earth masses) a body is a giant, gas or ice: past ten or so a planet holds on to an
## envelope of gas. On Tarsis it parts the service's types exactly: Tarsis V (GasGiant, 134) and VI
## (IceGiant, 38) from the rest, none over 1.4.
const GIANT_MIN_EARTHS: float = 10.0
## The mark before a body in the list: a planet, a moon, a giant.
const MARK_PLANET: String = "○"
const MARK_MOON: String = "●"
const MARK_GIANT: String = "◌"

## The bodies of a system, parents before their moons, each as
## `{ "key": "tarsis_3_1", "label": "Korax - Tarsis III.M1", "is_moon": true, "is_giant": false }`.
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
			"is_giant": float(props.get("orbit_mass_earths", 0.0)) >= GIANT_MIN_EARTHS,
		})
	return out


## The row of [param rows] (from [method bodies]) the list should open on: the first body with surveyed
## POI — the one real destination today, SandBox – Tarsis III — else the first row. 0 when empty.
static func preferred_body_index(rows: Array[Dictionary]) -> int:
	for i: int in range(rows.size()):
		if not poi_destinations(str(rows[i]["key"])).is_empty():
			return i
	return 0


## The mark of a body row from [method bodies]: ● a moon, ◌ a giant, ○ any other planet.
static func body_mark(row: Dictionary) -> String:
	if bool(row.get("is_moon", false)):
		return MARK_MOON
	return MARK_GIANT if bool(row.get("is_giant", false)) else MARK_PLANET


## Everywhere you can go on [param planet_name]: the stations orbiting it, its POI, then the derived
## points.
static func destinations(planet_name: String) -> Array[TeleportDestination]:
	var out: Array[TeleportDestination] = []
	out.append_array(station_destinations(planet_name))
	out.append_array(poi_destinations(planet_name))
	out.append_array(derived_destinations(planet_name))
	return out


## The stations orbiting [param planet_name], read from their StationSite files — never from the
## network, which only hands a client the stations within 200 km of it.
static func station_destinations(planet_name: String) -> Array[TeleportDestination]:
	var out: Array[TeleportDestination] = []
	var system: String = SystemScenes.system_of(planet_name)
	if system == "":
		return out
	var props: Dictionary = SystemScenes.body_properties(system, planet_name)
	for site: StationSite in StationSites.for_body(system, planet_name):
		out.append(station_destination(site, planet_name, props))
	return out


## The list entry of [param site], given its body's properties: named, and its orbit described.
static func station_destination(site: StationSite, planet_name: String,
		body_props: Dictionary) -> TeleportDestination:
	var detail: String = "orbit %.0f km, %.1f°" % [site.altitude_above(body_props) / 1000.0, site.inclination_deg]
	var dest := TeleportDestination.to_station(site, planet_name, detail)
	dest.group = GROUP_STATIONS
	return dest


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
		var dest := TeleportDestination.new(
				str(entry.get("name", "?")), planet_name,
				float(entry.get("lon", 0.0)), float(entry.get("lat", 0.0)),
				height, mode, TeleportDestination.Kind.POI,
				_poi_detail(entry))
		dest.group = str(entry.get("poi_type", ""))
		out.append(dest)
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
	for dest: TeleportDestination in out:
		dest.group = GROUP_COMPUTED
	return out


## [param list] by heading, as [[heading, destinations], …]: the stations first, then the POI types in
## alphabetical order, the computed points last; each heading's destinations in natural order (F0003
## before F0004, city_2 before city_11). The list came in file order, which read as no order at all.
static func grouped(list: Array[TeleportDestination]) -> Array:
	var by_group: Dictionary = {}
	for dest: TeleportDestination in list:
		var heading: String = dest.group if dest.group != "" else GROUP_POI
		if not by_group.has(heading):
			by_group[heading] = [] as Array[TeleportDestination]
		(by_group[heading] as Array[TeleportDestination]).append(dest)
	var headings: Array = by_group.keys()
	headings.sort_custom(func(a: String, b: String) -> bool:
		var ra: int = _group_rank(a)
		var rb: int = _group_rank(b)
		return ra < rb if ra != rb else a.naturalnocasecmp_to(b) < 0)
	var out: Array = []
	for heading: String in headings:
		var dests: Array[TeleportDestination] = by_group[heading]
		dests.sort_custom(func(a: TeleportDestination, b: TeleportDestination) -> bool:
			return a.label.naturalnocasecmp_to(b.label) < 0)
		out.append([heading, dests])
	return out


static func _group_rank(heading: String) -> int:
	if heading == GROUP_STATIONS:
		return 0
	if heading == GROUP_COMPUTED:
		return 2
	return 1


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
