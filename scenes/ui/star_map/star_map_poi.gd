class_name StarMapPoi
extends RefCounted

## The points of interest of one celestial body, read from the level design's own export.
##
## Source is [code]assets/qgis/export/<body>_poi.json[/code], written by the QGIS pipeline alongside the
## terrain. Reading it directly is what keeps the chart honest: the towns it marks are the towns the
## world actually has, at the coordinates the world actually placed them, with no second list to drift.
##
## Free of nodes on purpose, like [StarMapCamera] — parsing and placing are pure functions of the file,
## so they can be tested without a viewport or a planet.
##
## ⚠️ Only tarsis_3 carries any today (27); the other eighteen files are empty shells. Nothing here is
## specific to it, so the rest of the system lights up on its own the day level design fills them in.

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
