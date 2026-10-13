@tool
extends AnimatableBody3D


@export var _platform_interface: CanvasLayer


## The platform this system carries, as create_generic_object loads it (path from res://).
const PLATFORM_SCENE_PATH := "scenes/_universe/structures/industrial/vehicle_lift/platform/platform.tscn"

const PLATFORM_INITIAL_POSITION: Vector3 = Vector3(0.0,0.0,2.425)


var _is_platform_spawned: bool = false


# Cached PropSync child. Resolved lazily (not @onready) because the uuid facade below is used
# before _ready: spawn code assigns uuid right after instantiate(), before the node enters the tree.
var _sync: PropSync:
	get:
		if not is_instance_valid(_sync):
			_sync = PropSync.of(self)
		return _sync

# Networking facade: expose the PropSync child's uuid on the body so the depot can be resolved
# as a networked parent by uuid (same inline pattern as spawn_building).
var uuid: String:
	get:
		return _sync.uuid if _sync != null else ""
	set(value):
		if _sync != null:
			_sync.uuid = value


func _ready() -> void:
	# What stands on the platform rides this system as its child (platform_area_detection.gd): on the
	# clients that makes a crate on it follow it like cargo in a truck bed (PropNet.rides_parent).
	add_to_group(PropNet.RIDE_CARRIER_GROUP)
	if Engine.is_editor_hint():
		var railing: Node3D = get_node_or_null("Platform/Railing")
		var railing_json_path: StringName = &"res://scenes/_universe/structures/industrial/vehicle_lift/platform/railing_datas.json"
		
		if railing:
			VehicleLift.generate_railings(railing, railing_json_path)
	else:
		if GameOrchestrator.is_server():
			var parent_lift: Node3D = get_parent()
			if parent_lift is VehicleLift and parent_lift.has_method("platform_system_spawned"):
				parent_lift.platform_system_spawned()
			
			if not _is_platform_spawned:
				# Deferred: we enter props_list only after add_child, and the platform's parent_id is us.
				spawn_platform.call_deferred()


## SERVER: spawn the networked platform under this system, once. Its uuid is drawn from ours, so a lost
## is_platform_spawned flag upserts the same platform instead of piling copies.
func spawn_platform() -> void:
	if _is_platform_spawned or not is_inside_tree() or uuid == "":
		return
	_is_platform_spawned = true  # before spawning: apply_prop_data runs again on every update
	var platform_uuid := PropSpawn.stable_uuid("%s|platform" % uuid)
	NetworkOrchestrator.protected_prop_uuids[platform_uuid] = true  # world infrastructure
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": "vehicle_lift_platform",
		"uuid": platform_uuid,
		"position": {
			"x": PLATFORM_INITIAL_POSITION.x,
			"y": PLATFORM_INITIAL_POSITION.y,
			"z": PLATFORM_INITIAL_POSITION.z
		},
		"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
		"scenename": PLATFORM_SCENE_PATH,
		"parent_id": uuid,
		"name": "Platform"
	})


func _process(delta: float) -> void:
	pass


func update_interface_lift_progress(progress: float, eta: int, status: String) -> void:
	var platform = get_node_or_null("Platform") as RigidBody3D
	if platform:
		platform.update_display_progress(progress, eta, status)


func platform_spawned() -> void:
	var platform = get_node_or_null("Platform") as RigidBody3D
	if platform:
		$Spring.set_node_b(platform.get_path())
	_is_platform_spawned = true
	if _sync != null:
		_sync.server_prop_update({
			"is_platform_spawned": _is_platform_spawned
	})


# PropSync applies the replicated transform, then calls this with the full payload so the depot can
# apply its own machine state. Replaces the old client_channel_data_update override.
func apply_prop_data(_data: Dictionary) -> void:
	if "is_platform_spawned" in _data:
		_is_platform_spawned = _data["is_platform_spawned"]
