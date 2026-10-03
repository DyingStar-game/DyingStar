class_name SpawnKiosk
extends StaticBody3D

## A kiosk that hands out a prop (a truck in the garage) at a marker next to it.
##
## The CLIENT only says "this kiosk was pressed": the building's uuid + the kiosk's path inside it
## (PlayerServer "kiosk_spawn"). The SERVER owns everything else — which scene, which type, where, and
## whether it is allowed now — so a tampered client cannot spawn anything else nor anywhere else.
## Refused while ANYTHING solid stands in the spawn box, and for `spawn_cooldown` after a spawn.

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

## Text on the kiosks to display (also the "[E] ..." prompt when aimed at; a translation key works).
@export var kiosk_text: String = ""

@export_group("Spawn")
## Scene instanced at the marker when the button is pressed (e.g. truck.tscn). Its network type is
## read from the scene itself (PropSync.type_name, or the root's own type_name for a Vehicle); a
## scene with neither is not networked and is never spawned.
@export var spawn_scene: PackedScene
## Node whose global transform gives the spawned prop's position and orientation (its -Z is the
## prop's forward). Put it slightly above the floor.
@export var spawn_marker: Node3D
## Minimum delay (s) between two spawns from this kiosk. Raise it to limit spam, 0 = only the
## occupancy check.
@export var spawn_cooldown: float = 120.0
## Size (m) of the box, in the marker's frame, that must be empty for a spawn. Anything solid in it
## (player, vehicle, prop, rock, terrain) refuses the spawn; make it at least as big as the prop.
@export var clear_box_size: Vector3 = Vector3(4.0, 3.0, 8.0)
## Height (m) of the box's bottom above the marker, so the floor the prop lands on does not count as
## an obstacle. Lower it to also catch flat things lying on the floor.
@export var clear_box_lift: float = 0.2
## Maximum distance (m) between the player and the kiosk for the server to accept a press.
@export var use_range: float = 4.0

@onready var kiosk_interaction_area: Interactable = $KioskInteractionArea

## SERVER: a press is waiting for the next physics step (space queries are only legal there).
var _pending: bool = false
## SERVER: Time.get_ticks_msec() of the last spawn, -1 = never.
var _last_spawn_ms: int = -1
## SERVER: spawn_scene's network type, read once ("" = not networked); null = not read yet.
var _spawn_type: Variant = null

func _ready() -> void:
	kiosk_interaction_area.interacted.connect(_on_interaction_requested)
	if kiosk_text != "":
		kiosk_interaction_area.label = kiosk_text
	set_physics_process(false)
	if spawn_scene == null or spawn_marker == null:
		push_warning("SpawnKiosk %s: spawn_scene or spawn_marker not set, the button does nothing" % get_path())

## CLIENT: the player pressed the button — ask the server, naming only this kiosk.
func _on_interaction_requested(interactor: Node) -> void:
	if not (interactor is Player) or GameOrchestrator.is_server():
		return
	var building: Node = _building()
	if building == null:
		push_warning("SpawnKiosk %s: not inside a networked building (no PropSync)" % get_path())
		return
	interactor.client_send_action_to_server({
		"action": "kiosk_spawn",
		"target_uuid": str(PropSync.of(building).uuid),
		"kiosk": str(building.get_path_to(self)),
	})

## The networked building this kiosk belongs to: the nearest ancestor carrying a PropSync child.
func _building() -> Node:
	var n: Node = get_parent()
	while n != null and PropSync.of(n) == null:
		n = n.get_parent()
	return n

## SERVER: a validated press (PlayerServer checked the range). Spawns on the next physics step.
func server_request_spawn() -> void:
	if spawn_scene == null or spawn_marker == null:
		return
	if _scene_type() == "":
		print("🏪 Kiosk spawn refused: %s has no PropSync (nor type_name), it is not networked" \
				% spawn_scene.resource_path)
		return
	if _last_spawn_ms >= 0 and Time.get_ticks_msec() - _last_spawn_ms < int(spawn_cooldown * 1000.0):
		print("🏪 Kiosk spawn refused: cooldown (%d s left)" % ceili(
				spawn_cooldown - (Time.get_ticks_msec() - _last_spawn_ms) / 1000.0))
		return
	_pending = true
	set_physics_process(true)

func _physics_process(_delta: float) -> void:
	set_physics_process(false)
	if not _pending:
		return
	_pending = false
	var blocker: Object = _spawn_box_blocker()
	if blocker != null:
		var blocker_name: String = str((blocker as Node).name) if blocker is Node else str(blocker)
		print("🏪 Kiosk spawn refused: spawn area occupied by %s" % blocker_name)
		return
	_spawn()

## The GORC type of spawn_scene: its PropSync's type_name, else the root's own `type_name` (a Vehicle
## carries its networking itself, without PropSync). "" when it has neither. Instanced once (never
## added to the tree, so no _ready runs) and cached.
func _scene_type() -> String:
	if _spawn_type == null:
		_spawn_type = ""
		var probe: Node = spawn_scene.instantiate()
		var sync: PropSync = PropSync.of(probe)
		if sync != null:
			_spawn_type = str(sync.type_name)
		elif "type_name" in probe:
			_spawn_type = str(probe.type_name)
		probe.free()
	return _spawn_type

## First solid body in the spawn box, or null when it is empty. The building's own bodies (walls,
## floor, this kiosk) are excluded: they would always fill it.
func _spawn_box_blocker() -> Object:
	var box := BoxShape3D.new()
	box.size = clear_box_size
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = box
	var xf: Transform3D = spawn_marker.global_transform
	params.transform = Transform3D(xf.basis,
			xf.origin + xf.basis.y.normalized() * (clear_box_lift + clear_box_size.y * 0.5))
	params.collision_mask = Globals.MASK_SOLID
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var exclude: Array[RID] = []
	var building: Node = _building()
	_collect_body_rids(building if building != null else self, exclude)
	params.exclude = exclude
	var hits: Array[Dictionary] = get_world_3d().direct_space_state.intersect_shape(params, 1)
	return hits[0].get("collider") if not hits.is_empty() else null

func _collect_body_rids(node: Node, out: Array[RID]) -> void:
	if node is CollisionObject3D:
		out.append((node as CollisionObject3D).get_rid())
	for child in node.get_children():
		_collect_body_rids(child, out)

## Hand the prop to the network, placed at the marker in the frame of the networked parent it sits
## on (the planet): a prop left in world coordinates would drift away with the moving planet.
func _spawn() -> void:
	var net_parent: Node = PropSpawn.find_net_parent(spawn_marker)
	var world: Transform3D = spawn_marker.global_transform
	var local_pos: Vector3 = PropSpawn.to_parent_local(net_parent, world.origin)
	var local_basis: Basis = world.basis
	if net_parent is Node3D:
		local_basis = (net_parent as Node3D).global_basis.inverse() * world.basis
	var local_rot: Vector3 = local_basis.orthonormalized().get_euler()
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": _scene_type(),
		"uuid": UUID_UTIL.v4(),
		"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
		"rotation": {"x": local_rot.x, "y": local_rot.y, "z": local_rot.z},
		"scenename": spawn_scene.resource_path.trim_prefix("res://"),
		"parent_id": PropSpawn.net_parent_uuid(net_parent),
	})
	_last_spawn_ms = Time.get_ticks_msec()
	print("🏪 Kiosk spawn '%s' (%s)" % [spawn_scene.resource_path, _scene_type()])
