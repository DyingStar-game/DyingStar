@tool
extends AnimatableBody3D


@export var _platform_interface: CanvasLayer


const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

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
	if Engine.is_editor_hint():
		var railing: Node3D = get_node_or_null("Platform/Railing")
		var railing_json_path: StringName = &"res://addons/vehicle_lift/platform/railing_datas.json"
		
		if railing:
			VehicleLift.generate_railings(railing, railing_json_path)
	else:
		if not GameOrchestrator.is_server():
			print_rich("[color=crimson][client][/color][color=gold] platform _ready, position = %.3v, global_position = %.3v[/color]" % [position, global_position])
		else:
			print_rich("[color=dodger_blue][server][/color][color=gold] platform _ready, position = %.3v, global_position = %.3v[/color]" % [position, global_position])
			var parent_lift: Node3D = get_parent()
			if parent_lift is VehicleLift and parent_lift.has_method("platform_system_spawned"):
				parent_lift.platform_system_spawned()
			
			if not _is_platform_spawned:
				print_rich("[color=dodger_blue][server][/color][color=gold] platform_spawned ready : [/color][color=red]flag de platform non présent, je la spawn, parenté à [/color][color=gold]%s[/gold]" % uuid)
				var data := {
					"type": "vehicle_lift_platform",
					"uuid": UUID_UTIL.new().as_string(),
					"position": {
						"x": PLATFORM_INITIAL_POSITION.x,
						"y": PLATFORM_INITIAL_POSITION.y,
						"z": PLATFORM_INITIAL_POSITION.z
					},
					"rotation": {
						"x": 0.0,
						"y": 0.0,
						"z": 0.0
					},
					"scenename": "addons/vehicle_lift/platform/platform.tscn",
					"parent_id": uuid,
					"name": "Platform"
				}
				NetworkOrchestrator.spawn_prop_authoritative(data)
			else:
				print_rich("[color=dodger_blue][server][/color][color=gold] platform_spawned ready : [/color][color=green]flag de platform déjà présent[/color]")


func _process(delta: float) -> void:
	pass


func update_interface_lift_progress(progress: float, eta: int, status: String) -> void:
	var platform = get_node_or_null("Platform") as RigidBody3D
	if platform:
		platform.update_display_progress(progress, eta, status)
	#if _platform_interface:
		#_platform_interface.display_progress(progress, eta, status)


func platform_spawned() -> void:
	print_rich("[color=green]La plateform de %s a spawn[/color]" % name)
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
