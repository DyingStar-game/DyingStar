extends Node3D

@export var is_spawned: bool = false
@export var spawn_scene: String = ""
@export var radius_m: int = 0
@export var population: int = 0
@export var type: String = ""


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func apply_prop_data(data: Dictionary) -> void:
	if data.has("is_spawned"):
		is_spawned = data["is_spawned"]
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
		NetworkOrchestrator.spawn_prop_authoritative({
			"type": item_sync.type_name,
			"uuid": item_uuid,
			"scenename": item.scene_file_path.trim_prefix("res://"),
			"parent_id": parent_uuid,
			"name": str(item.name),
			"position": {"x": xform.origin.x, "y": xform.origin.y, "z": xform.origin.z},
			"rotation": {"x": rot.x, "y": rot.y, "z": rot.z},
		})
		spawned += 1
	layout.free()
	print("[PoiVillages] %s: %d items spawned from %s" % [name, spawned, path])

	s.server_prop_update({"is_spawned": true})
	
