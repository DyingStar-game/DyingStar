class_name AdminCleanupTool
extends Node3D

## Admin cleanup tool (toggle with key 2): casts a ray from the camera, draws a red aim
## line, and on left click asks the server to permanently delete the targeted prop. It only
## ever targets player-spawned props (mining rocks, boxes, mining depots) — never world or
## static props (buildings, planets, players). Emergency prod-cleanup tool.
##
## Flow: target prop -> Player.client_send_action_to_server({"action":"delete_prop", ...})
## -> server RPC removes the node -> existing delete path drops it from GORC and the DB.

## Prop type_name values this tool is allowed to delete. Everything else is ignored.
const DELETABLE: Array[String] = ["miningrock", "box", "mining_depot"]
## Max aim distance (meters).
const REACH: float = 1000.0
## Right-hand anchor on the player body (matches the mining tool's equipment_hand_offset),
## where the visible beam originates from.
const HAND_OFFSET: Vector3 = Vector3(0.4, 1.0, -0.4)

var _camera: Camera3D = null
var _player: Node = null
var _ray: RayCast3D = null
var _line: MeshInstance3D = null
var _line_mesh: ImmediateMesh = null
var _line_mat: StandardMaterial3D = null
var _active: bool = false
var _target: Node = null

## Wire the tool to the local player's camera and build the ray + beam. Called right after
## instancing (NOT in _ready, which runs on add_child before the camera is injected).
func setup(camera: Camera3D, player: Node) -> void:
	_camera = camera
	_player = player
	# Aim ray fired forward from the camera centre (the crosshair direction).
	_ray = RayCast3D.new()
	_ray.target_position = Vector3(0.0, 0.0, -REACH)
	_ray.collision_mask = 0xFFFFFFFF
	_ray.enabled = true
	_camera.add_child(_ray)
	# Unshaded vertex-coloured line, drawn in world space (top_level) each frame.
	_line_mat = StandardMaterial3D.new()
	_line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_mat.vertex_color_use_as_albedo = true
	_line_mesh = ImmediateMesh.new()
	_line = MeshInstance3D.new()
	_line.mesh = _line_mesh
	_line.material_override = _line_mat
	_line.top_level = true
	_line.visible = false
	add_child(_line)

func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return
	# Key 2 toggles the tool on/off (physical key, so it works on AZERTY too).
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_2:
		set_active(not _active)
		return
	# Left click deletes the current target while the tool is active.
	if _active and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_delete_target()

## Activate/deactivate the tool. Activating stows the player's other tool (exclusivity).
func set_active(on: bool) -> void:
	if _active == on:
		return
	_active = on
	if _line != null:
		_line.visible = on
		if not on:
			_line_mesh.clear_surfaces()
	if not on:
		_target = null
	elif _player != null and _player.has_method("stow_mining_tool"):
		_player.stow_mining_tool()  # put the previous tool away before showing this one
	print("🧹 Admin cleanup tool: %s" % ("ON (click to delete rock/box/depot)" if on else "OFF"))

func _physics_process(_delta: float) -> void:
	if not _active or _camera == null:
		return
	_update_target()
	_draw_line()

## Resolve what the ray hits to a deletable prop node (walks up to the node carrying uuid).
func _update_target() -> void:
	_target = null
	if _ray == null:
		return
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		return
	var node: Node = _ray.get_collider()
	while node != null and not (("uuid" in node) and ("type_name" in node)):
		node = node.get_parent()
	if node != null and node.type_name in DELETABLE and str(node.uuid) != "":
		_target = node

func _aim_end() -> Vector3:
	if _ray != null and _ray.is_colliding():
		return _ray.get_collision_point()
	return _camera.global_position - _camera.global_transform.basis.z * REACH

## Red line normally; turns yellow when aiming at a deletable prop. The beam starts at the
## player's right hand and ends where the player is looking (the camera ray hit point).
func _draw_line() -> void:
	_line_mesh.clear_surfaces()
	var col: Color = Color(1.0, 0.85, 0.1) if _target != null else Color(1.0, 0.15, 0.1)
	var start: Vector3 = (_player as Node3D).to_global(HAND_OFFSET) if _player is Node3D else _camera.global_position
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_mat)
	_line_mesh.surface_set_color(col)
	_line_mesh.surface_add_vertex(start)
	_line_mesh.surface_set_color(col)
	_line_mesh.surface_add_vertex(_aim_end())
	_line_mesh.surface_end()

func _delete_target() -> void:
	if _target == null:
		return
	var prop_type: String = str(_target.type_name)
	var prop_uuid: String = str(_target.uuid)
	print("🗑️ Admin delete request: type=%s uuid=%s" % [prop_type, prop_uuid])
	if _player != null and _player.has_method("client_send_action_to_server"):
		_player.client_send_action_to_server({
			"action": "delete_prop",
			"type": prop_type,
			"uuid": prop_uuid,
		})
	_target = null
