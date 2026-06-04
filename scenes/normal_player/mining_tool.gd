class_name MiningTool extends Node3D

# Mining gameplay encapsulated as a player component: it holds the perforator on
# a generic EquipmentMount, detects nearby/aimed mining rocks, runs the aim mode
# and the perforation animation. Networking stays in the player (which owns the
# connection): this node emits `sync_requested` when the local owner changes a
# replicated state, and the player calls `apply_remote()` / `server_set_tool()`.
#
# Setup: add this as a child node of the player in the scene (so its @export
# values show in the inspector), then call setup(camera_pivot, camera) from the
# player's _ready.

## Owner-only: a replicated state changed; the player relays it to the server.
signal sync_requested(data: Dictionary)
## The aim crosshair should be shown/hidden (the player forwards it to the UI).
signal aiming_changed(aiming: bool)

const PERFORATOR_SCENE := preload("res://assets/models/equipments/tools/mining/hammerdrill.glb")
const PERFORATION_DURATION := 5.0

@export_group("Aim")
## Mouse-sensitivity factor while aiming (1.0 = normal).
@export_range(0.1, 1.0) var aim_sensitivity_factor: float = 0.4
## Move-speed factor while aiming (1.0 = normal).
@export_range(0.1, 1.0) var aim_speed_factor: float = 0.4
## Max distance (m) to a mining rock to be allowed to enter aim mode.
@export var aim_rock_distance: float = 2.0
## Roll correction (deg) to keep the tool upright while aiming (model-dependent).
@export var aim_roll_deg: float = 0.0

@export_group("Perforation")
@export var perforation_hammer_freq: float = 10.0       # back-and-forth jabs per second
## Animate only the chisel/bit node (reciprocating) instead of the whole tool.
@export var animate_bit_only: bool = true
@export var bit_node_name: String = "hammerdrill_chiselflat"
## Local axis the bit slides along.
@export var bit_axis: Vector3 = Vector3(0, 0, 1)
@export var bit_amplitude: float = 0.06
@export var perforation_hammer_amplitude: float = 0.18  # whole-tool jab depth (m)
@export var perforation_shake_amplitude: float = 0.025  # tremble (m)

@export_group("Equipment placement")
## Mount position on the body. This is the PIVOT the held item rotates around when aiming.
@export var equipment_hand_offset: Vector3 = Vector3(0.4, 1.0, -0.4)
## Held item offset inside the mount. Shift it so the item's grip sits on the pivot above.
@export var equipment_item_offset: Vector3 = Vector3.ZERO
## Held item base rotation, to make the model point forward (-Z).
@export var equipment_item_rotation_deg: Vector3 = Vector3(0, -90, 0)
## Held item uniform scale.
@export var equipment_item_scale: float = 2.0

## True while aiming (read by the player to slow the mouse/movement).
var is_aiming: bool = false
## True during perforation (read by the player to freeze the mouse/movement).
var is_perforating: bool = false

var _camera: Camera3D = null
var _camera_pivot: Node3D = null
var _equipment_mount: EquipmentMount = null
var _perforator: Node3D = null
var _bit: Node3D = null
var _perforation_t: float = 0.0
var _perforator_rest_pos: Vector3 = Vector3.ZERO
var _bit_rest: Vector3 = Vector3.ZERO
var _rock_ray: RayCast3D = null
var _crosshair_shown: bool = false
var _last_head_sent: float = INF   # last camera pitch sent (throttle "head" sync)

## Inject the player's camera rig and build the equipment mount + perforator.
func setup(camera_pivot: Node3D, camera: Camera3D) -> void:
	_camera_pivot = camera_pivot
	_camera = camera
	# Aim raycast from the camera center (the crosshair direction). Created here so
	# it exists on EVERY instance (remote players reconstruct the aim too).
	_rock_ray = RayCast3D.new()
	_rock_ray.target_position = Vector3(0.0, 0.0, -(aim_rock_distance + 2.0))
	_rock_ray.collision_mask = 0xFFFFFFFF
	_camera.add_child(_rock_ray)
	_equipment_mount = EquipmentMount.new()
	_equipment_mount.name = "EquipmentMount"
	add_child(_equipment_mount)
	_equipment_mount.position = equipment_hand_offset  # the pivot the held item rotates around
	_equipment_mount.pitch_source = camera_pivot       # aim follows the camera pitch
	# First item: the mining perforator (hidden until equipped with 1/&).
	_perforator = PERFORATOR_SCENE.instantiate()
	_perforator.position = equipment_item_offset       # shift the model so its grip sits on the pivot
	_perforator.rotation_degrees = equipment_item_rotation_deg
	_perforator.scale = Vector3.ONE * equipment_item_scale
	_perforator.visible = false
	_equipment_mount.hold(_perforator)
	_perforator_rest_pos = _perforator.position
	_bit = _perforator.get_node_or_null(bit_node_name)
	if _bit:
		_bit_rest = _bit.position

func _process(delta: float) -> void:
	# Aim the held tool at the point under the crosshair on EVERY instance: the
	# owner uses its real camera; remote players use the camera driven by the
	# synced body rotation + "head" pitch -> the tool points where they aim, with
	# no extra networking.
	if _equipment_mount != null:
		if _perforator != null and _perforator.visible and _camera != null:
			_equipment_mount.aim_target = _aim_point()
			_equipment_mount.aim_up = global_transform.basis.y
			_equipment_mount.aim_roll_deg = aim_roll_deg
		else:
			_equipment_mount.aim_target = null
	# Perforation visual runs on EVERY instance, driven by is_perforating.
	_update_perforation_visual(delta)

## Owner only (called by the player's _process): aim mode, perforation control,
## camera-pitch ("head") replication.
func update_local(_delta: float) -> void:
	# Aim mode: only if the tool is equipped AND near a rock.
	var can_aim := _perforator != null and _perforator.visible and _is_near_mining_rock()
	is_aiming = Input.is_action_pressed("aim") and can_aim
	# The aim crosshair shows only while aiming AND looking at the rock.
	var looking := is_aiming and _is_looking_at_rock()
	if looking != _crosshair_shown:
		_crosshair_shown = looking
		aiming_changed.emit(looking)

	# Perforation control: start on left-click while aiming, stop on release or
	# after PERFORATION_DURATION. The visual is handled by _update_perforation_visual.
	if is_perforating:
		if not is_aiming or not Input.is_action_pressed("perforate"):
			_set_perforating(false)  # released -> cancelled, no effect
		elif _perforation_t >= PERFORATION_DURATION:
			# animation end -> the fracture would trigger HERE (server-side, TODO)
			_set_perforating(false)
	elif looking and Input.is_action_just_pressed("perforate"):
		_set_perforating(true)

	# Replicate the camera pitch ("head") while a tool is equipped, so other
	# players see where we aim. Throttled to meaningful changes.
	if _perforator and _perforator.visible:
		var head_q: float = snappedf(_camera_pivot.rotation.x, 0.02)
		if head_q != _last_head_sent:
			_last_head_sent = head_q
			sync_requested.emit({"action": "set_head", "head": head_q})

## Owner only: toggle the equipped tool and replicate the state.
func toggle_equip() -> void:
	if _perforator == null:
		return
	var equipped := not _perforator.visible
	_perforator.visible = equipped  # immediate local toggle (first-person view)
	# Send the equipped tool as a STATE (not a one-shot event) so other clients
	# always converge to the right state via the replicated "tools" property.
	sync_requested.emit({"action": "equip_tool", "tools": ("perforator" if equipped else "")})

## Server (authoritative): apply the equipped-tool state. The player rebroadcasts it.
func server_set_tool(tool_id: String) -> void:
	if _perforator:
		_perforator.visible = tool_id != ""

## Apply replicated state on remote players (tool visibility, camera aim, perforation).
func apply_remote(data: Dictionary) -> void:
	if data.has("tools") and _perforator:
		_perforator.visible = str(data["tools"]) != ""
	if data.has("head") and _camera_pivot:
		_camera_pivot.rotation.x = float(data["head"])
	if data.has("perforating"):
		_apply_perforating(bool(data["perforating"]))

# ── Internals ────────────────────────────────────────────────────────────────

## True if a mining rock (group "miningrock") is within aim range.
func _is_near_mining_rock() -> bool:
	for r in get_tree().get_nodes_in_group("miningrock"):
		if r is Node3D and global_position.distance_to((r as Node3D).global_position) <= aim_rock_distance:
			return true
	return false

## True if the camera is currently looking at a mining rock (camera raycast).
func _is_looking_at_rock() -> bool:
	if _camera == null:
		return false
	if _rock_ray == null:
		return false
	_rock_ray.force_raycast_update()
	var c = _rock_ray.get_collider()
	return c != null and c.is_in_group("miningrock")

## World point under the crosshair: camera-center raycast hit, else far forward.
func _aim_point() -> Vector3:
	if _camera == null:
		return global_position
	var origin: Vector3 = _camera.global_position
	var fwd: Vector3 = -_camera.global_transform.basis.z
	if _rock_ray != null:
		_rock_ray.force_raycast_update()
		if _rock_ray.is_colliding():
			return _rock_ray.get_collision_point()
	return origin + fwd * (aim_rock_distance + 2.0)

## Apply the perforating state locally (owner from input, remote from "perforating").
func _apply_perforating(active: bool) -> void:
	if active == is_perforating:
		return
	is_perforating = active
	_perforation_t = 0.0
	if not active and _perforator:
		_perforator.position = _perforator_rest_pos
		if _bit:
			_bit.position = _bit_rest

## Owner: set the perforating state AND replicate it so others see the animation.
func _set_perforating(active: bool) -> void:
	if active == is_perforating:
		return
	_apply_perforating(active)
	sync_requested.emit({"action": "set_perforating", "perforating": active})

## Advance and apply the jackhammer visual (runs on every instance while perforating).
func _update_perforation_visual(delta: float) -> void:
	if not is_perforating or _perforator == null:
		return
	_perforation_t += delta
	var phase: float = absf(sin(_perforation_t * perforation_hammer_freq * TAU))
	if animate_bit_only and _bit:
		# The chisel/bit reciprocates along its local axis; the body only trembles.
		_bit.position = _bit_rest + bit_axis * (phase * bit_amplitude)
		_perforator.position = _perforator_rest_pos + Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * perforation_shake_amplitude
	else:
		# Whole-tool jab along the aim (-Z) + tremble.
		var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * perforation_shake_amplitude
		_perforator.position = _perforator_rest_pos - Vector3(0.0, 0.0, phase * perforation_hammer_amplitude) + shake
