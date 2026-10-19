class_name StarMapPoi
extends RefCounted

## The points of interest of one celestial body, from two sources: the level design's own export, and
## the points of interest of the SERVICE the player owns.
##
## Source is [code]assets/qgis/export/<body>_poi.json[/code], written by the QGIS pipeline alongside the
## terrain. Reading it directly is what keeps the chart honest: the towns it marks are the towns the
## world actually has, at the coordinates the world actually placed them, with no second list to drift.
##
## The service's ones ([method service_entry]) come in the same shape through the same door, so the
## chart draws a town and a mission's delivery point the same way and one list cannot show what the
## other hides. They are merged by [StarMapPoiLayer], which owns the list a body is drawn from.
##
## Free of nodes on purpose, like [StarMapCamera] — parsing and placing are pure functions of the file,
## so they can be tested without a viewport or a planet.
##
## ⚠️ Only tarsis_3 carries any level-design POI today (140); the other eighteen files are empty shells.
## Nothing here is specific to it, so the rest of the system lights up on its own the day level design
## fills them in. The service's POIs are not tied to a body at all: they show up wherever they belong.

## Where the QGIS pipeline writes them. The [code].json[/code] extension matters: an exported build
## remaps scenes to [code].tscn.remap[/code] but leaves json alone, so this path is the same in the
## editor and in the shipped client. That distinction is exactly what broke the teleporter's list.
const POI_DIR: String = "res://assets/qgis/export"

## Words a level designer writes in a file name that should not be title-cased back at the player.
const KEEP_UPPER: Array[String] = ["hq", "poi", "lz"]


## Every point of interest of [param body_key], or an empty array — a body with no file, an empty file
## and a malformed file are all simply "no points of interest", never an error. The chart draws whatever
## it is given and says nothing when there is nothing.
static func load_for(body_key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if body_key == "":
		return out
	var path: String = "%s/%s_poi.json" % [POI_DIR, body_key]
	if not FileAccess.file_exists(path):
		return out
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return out
	var raw: Variant = (parsed as Dictionary).get("pois", [])
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item: Variant in (raw as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = _entry_from(item as Dictionary)
		if not entry.is_empty():
			out.append(entry)
	return out


## One record, with its ground direction resolved.
##
## The direction is body-fixed, which is the frame the chart draws a body in: the drawn sphere carries
## the same tilt-and-spin basis as [code]PlanetBody._place_at_time[/code], so a marker pinned to this
## direction turns with the planet for free and needs no update of its own.
static func _entry_from(src: Dictionary) -> Dictionary:
	if not src.has("lon") or not src.has("lat"):
		return {}
	var raw_name: String = str(src.get("name", ""))
	var kind: String = str(src.get("poi_type", "")).strip_edges()
	return {
		"name": raw_name,
		"label": pretty_name(raw_name),
		"kind": kind,
		"population": int(src.get("population", 0)),
		"radius_m": float(src.get("radius", 0.0)),
		"description": str(src.get("description", "")).strip_edges(),
		"dir": HEALPix.lonlat2vec(float(src["lon"]), float(src["lat"])),
		"lon": float(src["lon"]),
		"lat": float(src["lat"]),
	}


## The level design's POIs of [param body_key] plus every one of [param records] that belongs to it,
## in that order.
##
## Both sources in ONE list, in one function, because the chart reads it twice and the two reads have
## to agree: the layer draws by this order, and the search index stores indices into it
## ([code]_poi_focus[/code] and a result of the typeahead are both positions in this array). If the
## export were read alone by the search and the merge done only by the layer, a result would name a
## town the drawn list had pushed further down, and the camera would frame the wrong marker.
static func merged_for(body_key: String, records: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = load_for(body_key)
	for record: Variant in records:
		if not (record is Dictionary):
			continue
		# The body is the gate, not a second opinion here: it is the frame rule, and it belongs in the
		# one place that knows what a body key means (service_entry above).
		var entry: Dictionary = service_entry(record as Dictionary, body_key)
		if not entry.is_empty():
			out.append(entry)
	return out


## What a point of interest of the SERVICE becomes on the chart for [param body_key], or {} when it
## cannot be one.
##
## A service POI is not the level design's. It is stored as an offset from the body's OWN CENTRE in
## metres (`system`, `scene`, `x`, `y`, `z`, `radiusM` — see [method PlayerServices.poi_list]), where
## the export stores lon/lat on a unit sphere. The direction is that offset normalised, and lon/lat
## follow from it, because the chart's info card and its search index read those two keys directly
## and would crash on a record without them.
##
## The body check is HERE rather than in the caller, because a place means nothing without the frame
## it was measured in: `scene: tarsis_1` and `scene: tarsis_10` are two planets, not two spellings of
## one, and reading them as the same is the bug service-inventory reports as POI_SCENE_SYSTEM_MISMATCH.
## An empty `scene` is off-world — no body to stand on, and this layer draws on bodies only.
##
## The name is taken AS WRITTEN: it is a player's sentence ("Livraison Alpha — tarsis_3"), not a
## pipeline identifier, so it goes through neither [method pretty_name] (which would lowercase every
## word after the first) nor [method tr] (which would look for a translation key that is not one). An
## unnamed POI says so in the player's language rather than showing a uuid, which reads as a bug.
##
## The kind is the owner, not the kind of place: the service records who a POI belongs to and what it
## is FOR is exactly what its name says. Feeding `ownerType` to the icon table is what lets a mission
## point be tinted apart from a town without the rule engine growing a second axis.
static func service_entry(poi: Dictionary, body_key: String) -> Dictionary:
	if str_of(poi.get("scene")) != body_key:
		return {}
	var dir := Vector3(ServiceTypes.num(poi.get("x")), ServiceTypes.num(poi.get("y")),
			ServiceTypes.num(poi.get("z")))
	if dir.length_squared() <= 0.0:
		# A zero offset has no direction to pin to, and the origin is a spot the star occupies:
		# there is nothing to draw and nowhere to draw it.
		return {}
	var raw_name := str_of(poi.get("name"))
	dir = dir.normalized()
	var lonlat := HEALPix.vec2lonlat(dir)
	return {
		"name": raw_name,
		"label": label_of(raw_name),
		"kind": str_of(poi.get("ownerType")),
		"population": 0,
		"radius_m": ServiceTypes.float_of(poi.get("radiusM")),
		"description": str_of(poi.get("description")),
		"dir": dir,
		"lon": lonlat.x,
		"lat": lonlat.y,
		# Carried through so a click on the chart can name the POI back to the service.
		"service_id": str_of(poi.get("id")),
		"owner_type": str_of(poi.get("ownerType")),
	}


## The chart's label for a name a player wrote: the name itself, or the language's word for "this one
## has none" when there is not one. An uuid is never the answer — see [method service_entry].
static func label_of(raw_name: String) -> String:
	return raw_name if raw_name != "" else ServiceTypes.text("%%SVC_POI_UNNAMED")


## A service field that can be JSON null read as a string. [code]Dictionary.get[/code]'s default only
## applies to an ABSENT key, and a nullable column arrives as an explicit null.
static func str_of(value: Variant) -> String:
	return "" if value == null else str(value).strip_edges()


## [code]mining_village_02[/code] → [code]Mining village 02[/code].
##
## The file names are identifiers written for a pipeline, not labels written for a player. Showing them
## raw is the same mistake as showing a translation key: it reads as a bug even when nothing is wrong.
static func pretty_name(raw: String) -> String:
	var cleaned: String = raw.strip_edges().replace("_", " ").replace("-", " ")
	while cleaned.contains("  "):
		cleaned = cleaned.replace("  ", " ")
	if cleaned == "":
		return ""
	var words: PackedStringArray = cleaned.split(" ", false)
	var out: PackedStringArray = PackedStringArray()
	for i: int in range(words.size()):
		var word: String = words[i]
		if KEEP_UPPER.has(word.to_lower()):
			out.append(word.to_upper())
		elif i == 0:
			out.append(word.substr(0, 1).to_upper() + word.substr(1).to_lower())
		else:
			out.append(word.to_lower())
	return " ".join(out)


## Is this point on the side of the body facing [param camera_pos]?
##
## Without the test, the towns of the night side read straight through the globe and the chart shows
## twice as many as exist — a sphere is opaque to the eye but not to a billboard drawn with no depth
## test. Compared against the OUTWARD normal at the point, which on a sphere is the point itself.
static func faces_camera(world_pos: Vector3, normal: Vector3, camera_pos: Vector3) -> bool:
	return (camera_pos - world_pos).dot(normal) > 0.0
