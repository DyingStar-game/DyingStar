extends Node3D

@export var is_spawned: bool = false
## Set by Horizon when it needs this village's habs for new players (on top of the spawn when the
## village is loaded, a player nearby).
@export var spawn_requested: bool = false
@export var spawn_scene: String = ""
@export var radius_m: int = 0
@export var population: int = 0
@export var type: String = ""


func apply_prop_data(data: Dictionary) -> void:
	if data.has("is_spawned"):
		is_spawned = data["is_spawned"]
	if data.has("spawn_requested"):
		spawn_requested = data["spawn_requested"]
	if data.has("spawn_scene"):
		spawn_scene = data["spawn_scene"]
	if data.has("radius_m"):
		radius_m = data["radius_m"]
	if data.has("population"):
		population = data["population"]
	if data.has("type"):
		type = data["type"]
	if data.has("name"):
		name = data["name"]

	if not is_spawned and GameOrchestrator.is_server():
		# Deferred: create_generic_object calls us BEFORE registering this village in props_list, so
		# a child spawned right now could not find its parent_id and would sit in the pending queue.
		spawn_items.call_deferred()


func spawn_items() -> void:
	# The first apply_prop_data runs before add_child and before the uuid is assigned: wait for the
	# second one, when the village is a real networked frame its items can be parented to.
	if is_spawned or not is_inside_tree():
		return
	var s := PropSync.of(self)
	if s == null or s.uuid == "":
		return
	if spawn_scene == "":
		push_warning("[PoiVillages] %s: no spawn_scene, nothing to spawn" % name)
		return
	var path: String = spawn_scene if spawn_scene.begins_with("res://") else "res://" + spawn_scene
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("[PoiVillages] %s: spawn_scene '%s' not found" % [name, path])
		return
	is_spawned = true  # before spawning: apply_prop_data runs again on every replicated update

	# The items are published under OUR parent's frame, not under the village itself: their pose is
	# therefore composed with ours, so it is expressed in the frame parent_id names ("" = world).
	var parent_uuid: String = PropSpawn.parent_frame_uuid(self)
	var frame: Transform3D = transform if parent_uuid != "" else global_transform

	# get all items in this scene and create instances for them on the network
	# The layout is only read, never added to the tree: its items' own _ready (e.g. a mining_depot
	# placeholder self-spawning) must not run — the networked copies below replace them.
	var layout: Node = packed.instantiate()
	var spawned: int = 0
	for item in layout.get_children():
		var item_sync := PropSync.of(item)
		if item_sync == null or not (item is Node3D) or item.scene_file_path == "":
			continue  # decoration baked into the layout, not a networked prop
		var xform: Transform3D = frame * (item as Node3D).transform  # layout root = us -> parent frame
		var rot: Vector3 = xform.basis.get_euler()
		# Deterministic uuid: a server restart upserts the same items instead of piling duplicates.
		var item_uuid: String = PropSpawn.stable_uuid("%s|%s" % [s.uuid, item.name])
		NetworkOrchestrator.protected_prop_uuids[item_uuid] = true  # world infrastructure
		# The item's own network properties (its <type>_def.json), with the values set in the layout.
		var data: Dictionary = _def_properties(item, item_sync.type_name)
		data.merge({
			"type": item_sync.type_name,
			"uuid": item_uuid,
			"scenename": item.scene_file_path.trim_prefix("res://"),
			"parent_id": parent_uuid,
			"name": str(item.name),
			"position": {"x": xform.origin.x, "y": xform.origin.y, "z": xform.origin.z},
			"rotation": {"x": rot.x, "y": rot.y, "z": rot.z},
		}, true)
		if item_sync.type_name == "spawnbuilding":
			# A new building of this village, every apartment free: the layout node still carries
			# the script's defaults (test apartment, total 1 / available 0). poi_uuid ties it to us
			# for Horizon's apartment assignment (parent_id is our parent, not the village).
			var capacity: int = int(item.rows) * int(item.cols) * int(item.floors)
			data.merge({"poi_uuid": s.uuid, "apartments": [], "total": capacity, "available": capacity}, true)
		NetworkOrchestrator.spawn_prop_authoritative(data)
		spawned += 1
	layout.free()
	print("[PoiVillages] %s: %d items spawned from %s" % [name, spawned, path])

	s.server_prop_update({"is_spawned": true})


## {type_name: [property names]} read from items_def/<type>_def.json, shared by every village.
static var _def_cache: Dictionary = {}

## The properties the item's type declares in its def, with the item's current values. Properties
## the node does not have are skipped; vectors/colours become the {x, y, z} dicts the network uses.
func _def_properties(item: Node, type_name: String) -> Dictionary:
	if not _def_cache.has(type_name):
		var path := "%s/%s%s" % [ServerPropsIO.DEFS_DIR, type_name, ServerPropsIO.DEFS_SUFFIX]
		var dj = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		if typeof(dj) != TYPE_DICTIONARY:
			push_warning("[PoiVillages] no network definition %s" % path)
		_def_cache[type_name] = ServerPropsIO.parse_def(dj) if typeof(dj) == TYPE_DICTIONARY else []
	var out: Dictionary = {}
	for prop in _def_cache[type_name]:
		var value = item.get(prop)
		if value == null and not _has_property(item, prop):
			continue
		match typeof(value):
			TYPE_VECTOR3, TYPE_VECTOR3I:
				value = {"x": value.x, "y": value.y, "z": value.z}
			TYPE_VECTOR2, TYPE_VECTOR2I:
				value = {"x": value.x, "y": value.y}
			TYPE_COLOR:
				value = {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
			TYPE_STRING_NAME, TYPE_NODE_PATH:
				value = str(value)
			TYPE_OBJECT:
				continue  # a node / resource reference cannot travel over the network
		out[prop] = value
	return out


static func _has_property(obj: Object, prop: String) -> bool:
	for p in obj.get_property_list():
		if p["name"] == prop:
			return true
	return false
