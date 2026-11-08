class_name ShelfLabels
extends RefCounted

## The name a player reads on a depot's shelf: its aisle's letter and its number along the aisle ("A12"),
## worked out from the depot's shelf layout (CargoDepot.SHELVES_LAYOUT), so every depot, every peer and
## the board of crates to collect (CargoDepot) agree without anything replicated (playtest 2026-11-08).
##
## An aisle is the walk two rows of shelves face (a shelf's front is +X turned by its yaw), or one row
## against a wall. Aisles are lettered in order along X, shelves numbered along Z, the left row before the
## right at each step. The buffer rack (outside the rows) has no label.

const LAYOUT := "res://scenes/_universe/structures/industrial/cargo_depot_shelves.json"
## The buffer rack the storekeepers fill first: not in an aisle.
const BUFFER_SHELF := "shelf_cargo_temp_zone"

## Shelf name -> label, built once from the layout; and [position, name] of every shelf of it.
static var _labels: Dictionary = {}
static var _places: Array = []


## The label of the shelf [param shelf_name] ("A12"), "" for the buffer rack or a name the layout lacks.
static func label_of(shelf_name: String) -> String:
	_load()
	return str(_labels.get(shelf_name, ""))


## The label of [param shelf] (a Shelf in its depot): by its name, else by where it stands in the depot
## -- a shelf's network name may arrive after it was built, its place never lies (playtest 2026-11-08).
static func label_for(shelf: Node3D) -> String:
	var by_name := label_of(str(shelf.name))
	return by_name if by_name != "" else label_at(shelf.position)


## The label of the layout's shelf standing within half a metre of [param depot_position] (depot frame).
static func label_at(depot_position: Vector3) -> String:
	_load()
	for place: Array in _places:
		var p: Vector3 = place[0]
		if Vector2(p.x - depot_position.x, p.z - depot_position.z).length() < 0.5:
			return str(_labels.get(place[1], ""))
	return ""


static func _load() -> void:
	if not _labels.is_empty():
		return
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	var shelves: Array = layout if layout is Array else []
	_labels = labels_for(shelves)
	for shelf: Variant in shelves:
		if shelf is Dictionary:
			var at: Dictionary = shelf["position"]
			_places.append([Vector3(float(at["x"]), float(at["y"]), float(at["z"])), str(shelf["name"])])


## Every shelf of [param layout] (CargoDepot.SHELVES_LAYOUT entries: name, position, rotation) by its label.
## Pure, for the tests.
static func labels_for(layout: Array) -> Dictionary:
	# Rows: the shelves standing at one X (to the decimetre), all facing one way.
	var rows: Dictionary = {}  # x key -> {"facing", "shelves": [[z, name]]}
	for shelf: Variant in layout:
		if not (shelf is Dictionary) or str(shelf.get("name", "")) == BUFFER_SHELF:
			continue
		var key := roundf(float(shelf["position"]["x"]) * 10.0) / 10.0
		if not rows.has(key):
			rows[key] = {"facing": signf(cos(float(shelf["rotation"]["y"]))), "shelves": []}
		(rows[key]["shelves"] as Array).append([float(shelf["position"]["z"]), str(shelf["name"])])
	# Aisles, along X: a row facing +X and the next one facing -X across the walk make one; a row with
	# nobody across (against a wall) makes one alone.
	var xs: Array = rows.keys()
	xs.sort()
	var aisles: Array = []
	var i := 0
	while i < xs.size():
		var row: Dictionary = rows[xs[i]]
		if row["facing"] > 0.0 and i + 1 < xs.size() and rows[xs[i + 1]]["facing"] < 0.0:
			aisles.append([rows[xs[i]], rows[xs[i + 1]]])
			i += 2
		else:
			aisles.append([row])
			i += 1
	var out: Dictionary = {}
	for a: int in range(aisles.size()):
		var letter := String.chr(65 + a) if a < 26 else "Z%d" % a
		var shelves: Array = []
		for side: int in range((aisles[a] as Array).size()):
			for s: Array in aisles[a][side]["shelves"]:
				shelves.append([s[0], side, s[1]])
		shelves.sort_custom(func(l: Array, r: Array) -> bool:
			return l[0] < r[0] if not is_equal_approx(l[0], r[0]) else l[1] < r[1])
		for n: int in range(shelves.size()):
			out[shelves[n][2]] = "%s%02d" % [letter, n + 1]
	return out
