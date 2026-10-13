class_name SpawnKiosk
extends StaticBody3D

## A kiosk that hands out a prop (a truck in the garage) at a marker next to it.
##
## The CLIENT only says "this kiosk was pressed": the building's uuid + the kiosk's path inside it
## (PlayerServer "kiosk_spawn"). The SERVER owns everything else — which scene, which type, where, and
## whether it is allowed now — so a tampered client cannot spawn anything else nor anywhere else.
## Refused while ANYTHING solid stands in the spawn box, and for `spawn_cooldown` after a spawn.

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

## The networked building this kiosk belongs to (MarkerSpawn.building_of).
func _building() -> Node:
	return MarkerSpawn.building_of(self)

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

## The GORC type of spawn_scene (MarkerSpawn.scene_type), read once and cached.
func _scene_type() -> String:
	if _spawn_type == null:
		_spawn_type = MarkerSpawn.scene_type(spawn_scene)
	return _spawn_type

## First solid body in the spawn box, or null when it is empty (MarkerSpawn.blocker). The building's
## own bodies (walls, floor, this kiosk) are excluded: they would always fill it.
func _spawn_box_blocker() -> Object:
	var building: Node = _building()
	return MarkerSpawn.blocker(spawn_marker, clear_box_size, clear_box_lift, building if building != null else self)

## Hand the prop to the network at the marker (MarkerSpawn.spawn).
func _spawn() -> void:
	MarkerSpawn.spawn(spawn_scene, _scene_type(), spawn_marker)
	_last_spawn_ms = Time.get_ticks_msec()
	print("🏪 Kiosk spawn '%s' (%s)" % [spawn_scene.resource_path, _scene_type()])
