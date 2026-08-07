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

const PERFORATOR_SCENE := preload("res://assets/_universe/props/tools/tools/mining/hammerdrill.glb")
const PERFORATION_DURATION := 5.0
## Brief "rejected" jab when perforating off a fault: the bit lunges and snaps back.
const REJECT_DURATION := 0.3

@export_group("Aim")
## Mouse-sensitivity factor while aiming (1.0 = normal).
@export_range(0.1, 1.0) var aim_sensitivity_factor: float = 0.4
## Move-speed factor while aiming (1.0 = normal).
@export_range(0.1, 1.0) var aim_speed_factor: float = 0.4
## Max distance (m) to a mining rock to be allowed to enter aim mode.
@export var aim_rock_distance: float = 2.0
## Roll correction (deg) to keep the tool upright while aiming (model-dependent).
@export var aim_roll_deg: float = 0.0
## Orient the tool toward the aimed rock (look_at). Uncheck to keep it on the camera
## pitch only (no pointing at the rock).
@export var orient_tool_at_rock: bool = true

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

@export_group("Bit tip & reach")
## Chisel tip position in the PERFORATOR's local space. Calibrate it with the gizmo
## below: enable show_tip_gizmo, run, and adjust until the sphere sits on the tip.
@export var bit_tip_offset: Vector3 = Vector3.ZERO
## Show a small sphere at bit_tip_offset to calibrate it.
@export var show_tip_gizmo: bool = false
## Slide the perforator so the bit tip touches the rock at the aim point.
@export var reach_enabled: bool = true
## How fast the reach follows (higher = snappier).
@export var reach_smooth: float = 12.0
## Max forward extension (m), so the tool never flies off the hand.
@export var reach_max: float = 1.2

@export_group("Stow")
## Where the stowed tool sits, RELATIVE TO THE BELT BONE (player.belt_mount, a bone attachment on the
## animated puppet's hips): this is what places it on the mesh's belt, and it follows the body (walk/
## crouch/jump). Per-tool (each tool holsters differently). Only the stowed pose — the reach uses its own.
@export var stow_offset: Vector3 = Vector3(0.0, -0.5, 0.3)
## How fast the perforator eases back out of the stow when re-equipped (higher = snappier).
@export var stow_smooth: float = 10.0
## Rotation (deg) of the stowed tool relative to the belt bone.
@export var stow_rotation_deg: Vector3 = Vector3(5.0, -90.0, 95.1)

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
var _belt: Node3D = null  # cached shared belt mount (bone attachment on the puppet) — see _belt_mount
var _crosshair_shown: bool = false
var _target_rock_uuid: String = ""     # rock aimed when the perforation started
var _target_hit_local: Vector3 = Vector3.ZERO  # aim point, in that rock's local space
var _target_aim_dir: Vector3 = Vector3.ZERO    # perforation direction, in that rock's local space
var _target_on_fault: bool = false     # whether that aim point is on a fault (cuttable)
var _reject_t: float = -1.0            # >=0 while playing the off-fault "rejected" jab
var _perforator_base: Vector3 = Vector3.ZERO  # rest pos or reach target (the animation jabs on top of this)
var _tip_gizmo: MeshInstance3D = null  # debug sphere on the bit tip (calibration)
var _equipped: bool = false  # logical "tool equipped" state (visibility also depends on stow)
var _stowed: bool = false    # true while the perforator is stowed (player carrying an ore)

## Inject the player's camera rig and build the equipment mount + perforator.
func setup(camera_pivot: Node3D, camera: Camera3D) -> void:
	_camera_pivot = camera_pivot
	_camera = camera
	# Aim raycast from the camera center (the crosshair direction). Created here so it exists on EVERY
	# instance (remote players reconstruct the aim too). Hits rocks (bodies on `prop`; the caller
	# filters to the "miningrock" group).
	_rock_ray = Globals.make_camera_ray(_camera, aim_rock_distance + 2.0, 1 << (Globals.LAYER_PROP - 1))
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
	_perforator.visible = true   # always visible: stowed pose by default / at spawn (#124)
	_equipment_mount.hold(_perforator)
	_perforator_rest_pos = _perforator.position
	_perforator_base = _perforator_rest_pos   # sane init; the belt holster owns the stowed world pose
	_bit = _perforator.get_node_or_null(bit_node_name)
	if _bit:
		_bit_rest = _bit.position
	# Calibration gizmo: a small sphere at the bit tip, child of the perforator so it
	# follows the model. Move bit_tip_offset until it sits exactly on the chisel point.
	if show_tip_gizmo:
		_tip_gizmo = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.03
		sphere.height = 0.06
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 1.0, 0.3)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere.material = mat
		_tip_gizmo.mesh = sphere
		_tip_gizmo.position = bit_tip_offset
		_perforator.add_child(_tip_gizmo)

func _process(delta: float) -> void:
	# Aim the held tool at the point under the crosshair on EVERY instance: the
	# owner uses its real camera; remote players use the camera driven by the
	# synced body rotation + "head" pitch -> the tool points where they aim, with
	# no extra networking.
	if _equipment_mount != null:
		# Orient the tool toward the rock while perforating (both clicks) OR during the
		# off-fault "rejected" jab, so the failed attempt looks the same (orient + plunge
		# + snap back). During plain aiming it stays on the camera pitch.
		if not _perforator_active():
			# Stowed (carrying or not equipped): fixed lowered pose, no camera influence.
			_equipment_mount.aim_target = null
			_equipment_mount.follow_pitch = false
		elif orient_tool_at_rock and (is_perforating or _reject_t >= 0.0) and _camera != null:
			_equipment_mount.aim_target = _aim_point()
			_equipment_mount.aim_up = global_transform.basis.y
			_equipment_mount.aim_roll_deg = aim_roll_deg
			_equipment_mount.follow_pitch = true
		else:
			_equipment_mount.aim_target = null   # follow the camera pitch only
			_equipment_mount.follow_pitch = true
	# Calibration: keep the gizmo on bit_tip_offset (tunable live via the remote inspector).
	if _tip_gizmo != null:
		_tip_gizmo.position = bit_tip_offset
	# Stow/unstow + reach drive where the perforator sits and its visibility. Runs on
	# EVERY instance, so the stow lerp is seen by all players (issue #124).
	_update_stow_and_reach(delta)
	if _perforator != null:
		_perforator.position = _perforator_base   # default; the visuals jab on top of it
		# Stowed: holster the tool on the shared belt mount (a bone attachment on the animated puppet) with
		# THIS tool's own offset, so it follows the body (walk/crouch/jump). (The owner doesn't see his own
		# stowed tool; this is for remotes.) Falls back to the fixed mount pose if the puppet has no belt.
		var belt: Node3D = _belt_mount()
		if belt != null and not _perforator_active():
			_perforator.global_transform = belt.global_transform * _holster_transform()
	# Perforation visual runs on EVERY instance, driven by is_perforating.
	_update_perforation_visual(delta)
	# Off-fault "rejected" jab (owner-local feedback): the bit lunges out then snaps back.
	_update_reject_visual(delta)

## The shared belt attachment point on the animated puppet (a BoneAttachment3D on the hip bone, created
## once by CharacterAnimator). ANY tool holsters onto it with its OWN offset — the mount is generic, the
## offset is per-tool. Cached; null (fall back to the fixed pose) until the puppet + mount exist.
func _belt_mount() -> Node3D:
	if _belt != null:
		return _belt
	var body: Node = get_parent()
	if body != null and "belt_mount" in body:
		_belt = body.belt_mount
	return _belt

## This tool's stowed pose relative to the belt mount — places it on the mesh's belt (per-tool). Keeps the
## tool's own scale (setting global_transform would otherwise inherit the bone's).
func _holster_transform() -> Transform3D:
	var basis := Basis.from_euler(stow_rotation_deg * (PI / 180.0)).scaled(Vector3.ONE * equipment_item_scale)
	return Transform3D(basis, stow_offset)

## Decide the perforator's rest target: stowed pose (carrying an ore) vs reach. The tool
## STAYS visible at the stow pose (just lowered), it is not hidden — for everyone (#124).
func _update_stow_and_reach(delta: float) -> void:
	var active := _perforator_active()
	if active:
		_update_reach(delta)
	else:
		# Stowed: the belt holster sets the real world pose (see _process, on the animated hips). Keep the
		# base easing to rest so re-equipping slides out cleanly, and as the no-puppet fallback.
		_perforator_base = _perforator_base.lerp(_perforator_rest_pos, clampf(stow_smooth * delta, 0.0, 1.0))
	if _perforator != null:
		# Visible to OTHER players when stowed (pose at spawn), but the local owner does
		# NOT see his own stowed perforator (first-person clutter). Always visible when out.
		_perforator.visible = active or not _is_owner()
		# Orientation: item base rotation when out, fixed stow rotation when stowed.
		_perforator.rotation_degrees = equipment_item_rotation_deg if active else stow_rotation_deg

## Lerp the perforator so the bit TIP lands exactly on the rock at the aim point — full
## 3D (including the tip's lateral offset, not just depth). Only while actively aiming
## (right-click) or perforating; otherwise it returns to its rest position.
func _update_reach(delta: float) -> void:
	var target := _perforator_rest_pos
	# Reach ONLY while perforating (left-click), not during mere aiming — otherwise the
	# tip slides on the surface as the crosshair moves. The player is frozen while
	# perforating, so the tip stays put once engaged.
	if reach_enabled and _equipment_mount != null and _perforator_active() \
			and (is_perforating or _reject_t >= 0.0):
		var hit: Vector3 = _aim_point()
		# Solve the perforator position so the tip (basis * bit_tip_offset) == hit.
		target = _equipment_mount.to_local(hit) - (_perforator.basis * bit_tip_offset)
		var off: Vector3 = target - _perforator_rest_pos
		if off.length() > reach_max:
			target = _perforator_rest_pos + off.normalized() * reach_max   # don't fly off the hand
	_perforator_base = _perforator_base.lerp(target, clampf(reach_smooth * delta, 0.0, 1.0))

## Owner only (called by the player's _process): aim mode, perforation control,
## camera-pitch ("head") replication.
func update_local(_delta: float) -> void:
	# Aim mode: only if the tool is equipped AND near a rock.
	var can_aim := _perforator_active() and _is_near_mining_rock()
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
			_emit_perforate()  # animation complete -> fracture the targeted rock
			_set_perforating(false)
	elif looking and Input.is_action_just_pressed("perforate"):
		_capture_target()
		if _target_rock_uuid != "" and _target_on_fault:
			_set_perforating(true)            # on a fault -> real perforation
		else:
			_reject_t = 0.0                   # off a fault -> brief rejected jab, no cut

	# Camera pitch ("head") is now a generic player property sent by NormalPlayer
	# (tech-debt A), not here — MiningTool only consumes it via apply_remote().

## Owner only: toggle the equipped tool and replicate the state.
func toggle_equip() -> void:
	set_equipped(not _equipped)

## Explicitly equip/unequip (used for tool exclusivity: selecting another tool stows this one).
func set_equipped(on: bool) -> void:
	if _perforator == null or _equipped == on:
		return
	_equipped = on  # visibility is derived in _process (also depends on stow)
	# Send the equipped tool as a STATE (not a one-shot event) so other clients
	# always converge to the right state via the replicated "tools" property.
	sync_requested.emit({"action": "update_property", "tools": ("perforator" if _equipped else "")})

func is_equipped() -> bool:
	return _equipped

## Server (authoritative): apply the equipped-tool state. The player rebroadcasts it.
func server_set_tool(tool_id: String) -> void:
	_equipped = tool_id != ""  # visibility is derived in _process (server doesn't render)

## Apply replicated state on remote players (tool visibility, camera aim, perforation).
func apply_remote(data: Dictionary) -> void:
	if data.has("tools"):
		_equipped = str(data["tools"]) != ""
	# NOTE: the look pitch ("head") is applied to the camera pivot by PlayerClient (a general player
	# property); MiningTool only READS the pivot to aim the tool (see update()). Tech-debt A resolved.
	if data.has("perforating"):
		_apply_perforating(bool(data["perforating"]))
	if data.has("carrying"):
		set_stowed(bool(data["carrying"]))

## Stow/unstow the perforator (player carrying an ore). The visual lerp runs in _process
## on every instance, so it is visible to all players. Owner predicts it on the carry key;
## remotes get it via the replicated "carrying" player property.
func set_stowed(value: bool) -> void:
	_stowed = value

## The perforator can aim / reach only when equipped and not stowed.
func _perforator_active() -> bool:
	return _perforator != null and _equipped and not _stowed

## True if this tool belongs to the LOCAL player (not a replicated remote player). Used
## so the owner doesn't see his own stowed perforator while others still do.
func _is_owner() -> bool:
	var p = get_parent()
	return not (p != null and "remote_player" in p and p.remote_player)

# ── Internals ────────────────────────────────────────────────────────────────

## True if a mining rock (group "miningrock") is within aim range. Distance is measured to
## the rock's SURFACE (center distance minus its radius), so big variants — whose center is
## metres deep — are reachable like the small one (which has a ~0 radius -> unchanged).
func _is_near_mining_rock() -> bool:
	for r in get_tree().get_nodes_in_group("miningrock"):
		if r is Node3D:
			var radius: float = r.aim_radius() if r.has_method("aim_radius") else 0.0
			if global_position.distance_to((r as Node3D).global_position) - radius <= aim_rock_distance:
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

## Capture the rock under the crosshair + the aim point (in the rock's local space)
## when a perforation starts, so we can fracture exactly there at the end.
func _capture_target() -> void:
	_target_rock_uuid = ""
	_target_on_fault = false
	if _rock_ray != null:
		_rock_ray.force_raycast_update()   # fresh hit before capturing the target
	if _rock_ray == null or not _rock_ray.is_colliding():
		return
	var rock = _rock_ray.get_collider()
	if rock != null and rock.is_in_group("miningrock") and "uuid" in rock:
		_target_rock_uuid = str(rock.uuid)
		var hit_world: Vector3 = _rock_ray.get_collision_point()
		_target_hit_local = (rock as Node3D).to_local(hit_world)
		# Perforation direction (camera forward) in the rock's local space, so the server
		# can recoil the pieces away from the bit.
		var dir_world: Vector3 = -_camera.global_transform.basis.z if _camera != null else Vector3.FORWARD
		_target_aim_dir = ((rock as Node3D).to_local(hit_world + dir_world) - _target_hit_local).normalized()
		# Only a hit on a fault is cuttable; elsewhere the perforation just bounces off.
		if rock.has_method("is_on_fault"):
			_target_on_fault = rock.is_on_fault(_target_hit_local)

## Owner: ask the server to fracture the targeted rock at the captured point.
func _emit_perforate() -> void:
	if _target_rock_uuid == "":
		return
	sync_requested.emit({
		"action": "perforate_rock",
		"uuid": _target_rock_uuid,
		"hit": {"x": _target_hit_local.x, "y": _target_hit_local.y, "z": _target_hit_local.z},
		"dir": {"x": _target_aim_dir.x, "y": _target_aim_dir.y, "z": _target_aim_dir.z},
	})

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
	sync_requested.emit({"action": "update_property", "perforating": active})

## Advance and apply the jackhammer visual (runs on every instance while perforating).
func _update_perforation_visual(delta: float) -> void:
	if not is_perforating or _perforator == null:
		return
	_perforation_t += delta
	var phase: float = absf(sin(_perforation_t * perforation_hammer_freq * TAU))
	if animate_bit_only and _bit:
		# The chisel/bit reciprocates along its local axis; the body only trembles.
		_bit.position = _bit_rest + bit_axis * (phase * bit_amplitude)
		_perforator.position = _perforator_base + Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * perforation_shake_amplitude
	else:
		# Whole-tool jab along the aim (-Z) + tremble.
		var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * perforation_shake_amplitude
		_perforator.position = _perforator_base - Vector3(0.0, 0.0, phase * perforation_hammer_amplitude) + shake

## Owner-local feedback when perforating off a fault: one quick out-and-back jab, then
## the tool snaps back to rest. Nothing is sent to the server (no cut).
func _update_reject_visual(delta: float) -> void:
	if _reject_t < 0.0 or _perforator == null or is_perforating:
		return
	_reject_t += delta
	if _reject_t >= REJECT_DURATION:
		_reject_t = -1.0
		_perforator_base = _perforator_rest_pos   # abrupt snap back to rest (no slow lerp)
		_perforator.position = _perforator_rest_pos
		if _bit:
			_bit.position = _bit_rest
		return
	var jab: float = sin((_reject_t / REJECT_DURATION) * PI)   # 0 -> 1 -> 0
	if _bit:
		_bit.position = _bit_rest + bit_axis * (jab * bit_amplitude)
	else:
		_perforator.position = _perforator_base - Vector3(0.0, 0.0, jab * perforation_hammer_amplitude)
