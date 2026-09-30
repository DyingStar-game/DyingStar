class_name PropRegistry
extends RefCounted
## SERVER: every prop of our zones, as DATA, whether or not its scene is in the tree.
##
## Horizon sends the whole persisted world at boot (tens to hundreds of thousands of items). Only the
## items where someone stands need a node: on a planet, those on the terrain chunks the server keeps
## resident anyway (zone ∪ pins — one residency decision for the ground AND what stands on it); in
## space, or aloft over a planet, those within their type's load radius of a viewer (ItemDefs). The
## rest sleeps here as the last known object_data and is created again when someone comes back.
##
## Pure bookkeeping — no node, no scene tree — so it is unit-testable. GameServer decides where an item
## lives (it knows the planets and the viewers) and calls place_*; this class only indexes.
##
## Where an item is indexed ("kind"):
##   KIND_GROUND  root on a planet's ground: by_chunk[planet][key] (fine key and, when coarser, the
##                export key — the zone residency speaks export keys, the pins fine keys)
##   KIND_RADIUS  root in space or aloft over a planet: grid[world][radius][cell], for a distance test
##   KIND_CHILD   parented to another registry item: children_of[parent]; lives and sleeps with it
##   KIND_ALWAYS  never sleeps: carried by a player, no position, no definition, planet without terrain
##   KIND_WAITING parent not known yet: waiting[parent]; placed again when the parent shows up

const KIND_GROUND := 0
const KIND_RADIUS := 1
const KIND_CHILD := 2
const KIND_ALWAYS := 3
const KIND_WAITING := 4

## uuid -> entry:
##   uuid, type, event (the Horizon event, object_data kept up to date), kind, world, pos (world-local),
##   keys (PackedStringArray, KIND_GROUND), radius + cell (KIND_RADIUS), parent (KIND_CHILD/WAITING),
##   node (null while asleep), far_since_ms (0 = wanted)
var entries: Dictionary = {}
var by_chunk: Dictionary = {}      # world -> {key -> {uuid: true}}
var grid: Dictionary = {}          # world -> {radius (float) -> {Vector3i -> {uuid: true}}}
var children_of: Dictionary = {}   # parent uuid -> {uuid: true}
var waiting: Dictionary = {}       # unknown parent uuid -> {uuid: true}
var live: Dictionary = {}          # uuid -> true, the entries that have a node


func has(uuid: String) -> bool:
	return entries.has(uuid)


func get_entry(uuid: String) -> Dictionary:
	return entries.get(uuid, {})


func size() -> int:
	return entries.size()


## Record (or refresh) the data of an item. Returns its entry; the caller places it next.
func upsert(event: Dictionary) -> Dictionary:
	var data: Dictionary = event["data"]
	var uuid: String = str(data["object_uuid"])
	var entry: Dictionary = entries.get(uuid, {})
	if entry.is_empty():
		entry = {
			"uuid": uuid, "type": str(data.get("object_type", "")), "event": event,
			"kind": -1, "world": "", "pos": Vector3.ZERO, "keys": PackedStringArray(),
			"radius": 0.0, "cell": Vector3i.ZERO, "parent": "", "node": null, "far_since_ms": 0,
		}
		entries[uuid] = entry
	else:
		merge_data(uuid, data.get("object_data", {}))
	return entry


## Merge replicated properties into the stored object_data. Vector3 values (what PropNet emits) are
## stored as {x, y, z} dictionaries, the shape Horizon sends back.
func merge_data(uuid: String, props: Dictionary) -> void:
	var entry: Dictionary = entries.get(uuid, {})
	if entry.is_empty():
		return
	var od: Dictionary = entry["event"]["data"].get("object_data", {})
	for k in props:
		var v: Variant = props[k]
		if v is Vector3:
			od[k] = {"x": (v as Vector3).x, "y": (v as Vector3).y, "z": (v as Vector3).z}
		else:
			od[k] = v
	entry["event"]["data"]["object_data"] = od


# ── Placement ────────────────────────────────────────────────────────────────

func place_ground(uuid: String, world: String, pos: Vector3, keys: PackedStringArray) -> void:
	var e := _unplace(uuid)
	e["kind"] = KIND_GROUND
	e["world"] = world
	e["pos"] = pos
	e["keys"] = keys
	var chunks: Dictionary = by_chunk.get(world, {})
	by_chunk[world] = chunks
	for k in keys:
		var bucket: Dictionary = chunks.get(k, {})
		bucket[uuid] = true
		chunks[k] = bucket


func place_radius(uuid: String, world: String, pos: Vector3, radius: float) -> void:
	var e := _unplace(uuid)
	e["kind"] = KIND_RADIUS
	e["world"] = world
	e["pos"] = pos
	e["radius"] = radius
	var cell := cell_of(pos, radius)
	e["cell"] = cell
	var classes: Dictionary = grid.get(world, {})
	grid[world] = classes
	var cells: Dictionary = classes.get(radius, {})
	classes[radius] = cells
	var bucket: Dictionary = cells.get(cell, {})
	bucket[uuid] = true
	cells[cell] = bucket


func place_child(uuid: String, parent: String) -> void:
	var e := _unplace(uuid)
	e["kind"] = KIND_CHILD
	e["parent"] = parent
	var kids: Dictionary = children_of.get(parent, {})
	kids[uuid] = true
	children_of[parent] = kids


func place_always(uuid: String) -> void:
	var e := _unplace(uuid)
	e["kind"] = KIND_ALWAYS


func place_waiting(uuid: String, parent: String) -> void:
	var e := _unplace(uuid)
	e["kind"] = KIND_WAITING
	e["parent"] = parent
	var w: Dictionary = waiting.get(parent, {})
	w[uuid] = true
	waiting[parent] = w


## The uuids that were waiting for [param parent]; they are no longer waiting (the caller places them).
func take_waiting(parent: String) -> Array:
	var w: Dictionary = waiting.get(parent, {})
	waiting.erase(parent)
	var out: Array = w.keys()
	for u in out:
		var e: Dictionary = entries.get(u, {})
		if not e.is_empty() and e["kind"] == KIND_WAITING:
			e["kind"] = -1
	return out


## Remove [param uuid] from every index (not from entries). Returns its entry.
func _unplace(uuid: String) -> Dictionary:
	var e: Dictionary = entries[uuid]
	match int(e["kind"]):
		KIND_GROUND:
			var chunks: Dictionary = by_chunk.get(e["world"], {})
			for k in e["keys"]:
				var bucket: Dictionary = chunks.get(k, {})
				bucket.erase(uuid)
				if bucket.is_empty():
					chunks.erase(k)
			e["keys"] = PackedStringArray()
		KIND_RADIUS:
			var cells: Dictionary = grid.get(e["world"], {}).get(e["radius"], {})
			var bucket: Dictionary = cells.get(e["cell"], {})
			bucket.erase(uuid)
			if bucket.is_empty():
				cells.erase(e["cell"])
		KIND_CHILD:
			var kids: Dictionary = children_of.get(e["parent"], {})
			kids.erase(uuid)
			if kids.is_empty():
				children_of.erase(e["parent"])
		KIND_WAITING:
			var w: Dictionary = waiting.get(e["parent"], {})
			w.erase(uuid)
			if w.is_empty():
				waiting.erase(e["parent"])
	e["kind"] = -1
	return e


## Drop [param uuid] and everything parented to it, recursively. Returns the dropped entries (the
## caller frees their nodes). Items waiting for it stay waiting: the parent may come back.
func forget(uuid: String) -> Array:
	var out: Array = []
	for u in subtree(uuid):
		if not entries.has(u):
			continue
		var e := _unplace(u)
		entries.erase(u)
		live.erase(u)
		out.append(e)
	return out


## [param uuid] and its registry descendants, parents before children.
func subtree(uuid: String) -> Array:
	var out: Array = [uuid]
	var i := 0
	while i < out.size():
		for c in children_of.get(out[i], {}):
			out.append(c)
		i += 1
	return out


# ── Queries ──────────────────────────────────────────────────────────────────

## Grid cell of [param pos] for items of load radius [param radius]: one cell per radius, so the 27
## cells around a viewer hold every candidate within that radius.
static func cell_of(pos: Vector3, radius: float) -> Vector3i:
	return Vector3i(floori(pos.x / radius), floori(pos.y / radius), floori(pos.z / radius))


func uuids_on_chunk(world: String, key: String) -> Array:
	return by_chunk.get(world, {}).get(key, {}).keys()


## KIND_RADIUS roots of [param world] within their own radius × [param factor] of [param viewer].
func uuids_near(world: String, viewer: Vector3, factor: float) -> Array:
	var out: Array = []
	var classes: Dictionary = grid.get(world, {})
	for radius in classes:
		var reach: float = float(radius) * factor
		var r2: float = reach * reach
		var cells: Dictionary = classes[radius]
		var c := cell_of(viewer, radius)
		var span: int = ceili(factor)
		for dx in range(-span, span + 1):
			for dy in range(-span, span + 1):
				for dz in range(-span, span + 1):
					var bucket: Dictionary = cells.get(c + Vector3i(dx, dy, dz), {})
					for u in bucket:
						if (entries[u]["pos"] as Vector3).distance_squared_to(viewer) <= r2:
							out.append(u)
	return out


## Is [param entry] (KIND_GROUND) standing on one of [param resident] chunk keys?
static func on_resident_chunk(entry: Dictionary, resident: Dictionary) -> bool:
	for k in entry["keys"]:
		if resident.has(k):
			return true
	return false
