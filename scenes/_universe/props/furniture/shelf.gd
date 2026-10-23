@tool
class_name Shelf
extends StaticBody3D

## A shelf with a grid of discrete storage SLOTS. A carried crate dropped near a free slot is taken
## UNDER the shelf (reparented), set on that slot and left dynamic until it rests on its tier, then
## frozen there (server-authoritative). Picking it up reparents it straight from the shelf to the
## player: the pickup calls [method release_cargo] on the crate's parent, the truck bed's contract.
##
## Why a child and not a world prop beside the shelf: the freeze that keeps a stored crate up is never
## persisted, so whatever re-creates the crate (a restart, a zone split or merge) must find the shelf
## already there. As a child, the crate comes after its shelf by construction — PropRegistry KIND_CHILD
## on the server, parent_id on the clients. As a world prop it was streamed on its own, nearest first:
## on a hand-over, with a player in the depot, the crates came back awake before their depot and fell
## through every tier to the floor (2026-10-23).
##
## Whatever wakes a stored crate afterwards (the settle-culler near a player, a zone hand-over, a ground
## hold released) the shelf freezes it again once it rests (_watch_stored).

@export_group("Shelf")
## Local (shelf-space) positions of every slot: where a stored crate's origin is set down, a few
## centimetres above its tier so it settles onto it. Authored in the scene.
@export var shelf_slots: Array[Vector3] = []
## Editor button: print this shelf as the JSON block the NPC service consumes (scenename + slots).
@export_tool_button("export to NPC service") var _export_npc_service = _export_to_npc_service
## Per-slot occupancy, parallel to shelf_slots. Initialised in _ready if left empty in the scene.
@export var shelf_slots_occupied: Array[bool] = []

## How far a dropped crate's centre may be from a free slot for that slot to swallow it (metres).
const SLOT_SNAP_RANGE := 2.0
## How many physics frames to keep re-sending a just-frozen crate's resting pose, so a single lost
## packet can't strand its replica mid-air (the frozen body won't resend on its own).
const _STORE_RESEND_FRAMES := 15
## A stored crate counts as resting below this speed (m/s) and _SETTLE_ANGULAR (rad/s)...
const _SETTLE_LINEAR := 0.05
const _SETTLE_ANGULAR := 0.2
## ...for this many consecutive physics frames, then it is frozen.
const _SETTLE_FRAMES := 10
## Frozen anyway after this many physics frames still moving (jittering against a neighbour).
const _SETTLE_TIMEOUT_FRAMES := 300
## How often (physics frames) the stored crates are checked for a wake-up by someone else.
const _WATCH_EVERY := 30
## Retry window (physics frames) to bind occupied slots after a restore, and how often to retry within
## it. Crates under the shelf bind as they arrive; this is for slots whose crate never comes, and for
## crates stored before they were parented to the shelf (world props resting on a slot).
const _REBIND_FRAMES := 600
const _REBIND_EVERY := 30
## Client: a stored crate stays in the physics space only this close to the camera (m), so the
## InteractRay (3 m) can still find it; checked every _REACH_EVERY_S seconds.
const _REACH_M := 4.0
const _REACH_EVERY_S := 0.25
## Client: whether a stored crate is in the physics space right now (see _client_set_in_space).
const _META_IN_SPACE := &"shelf_in_space"
## Client: whether a stored crate is dressed as near the camera right now (see _client_dress).
const _META_DRESSED_NEAR := &"shelf_dressed_near"
## Client: the cast_shadow a stored crate's mesh had before the shelf turned it off (see _client_dress).
const _META_CAST_SHADOW := &"shelf_cast_shadow"

## Client: every crate stored on a shelf, for the reach check (_client_reach_loop).
static var _client_stored: Array[CollisionObject3D] = []
static var _client_reach_running: bool = false

# Cached PropSync child. Resolved lazily (not @onready) because the uuid facade below is used
# before _ready: spawn code assigns uuid right after instantiate(), before the node enters the tree.
var _sync: PropSync:
	get:
		if not is_instance_valid(_sync):
			_sync = PropSync.of(self)
		return _sync

# Networking facade: expose the PropSync child's uuid on the body so the shelf resolves as the
# networked parent of the crates stored on it (PropSpawn.parent_frame_uuid, Server._search_parent_node).
var uuid: String:
	get:
		return _sync.uuid if _sync != null else ""
	set(value):
		if _sync != null:
			_sync.uuid = value

# Server-only: the crate body occupying each slot (parallel to shelf_slots), null when free.
var _slot_bodies: Array = []
# Server-only: stored crates still coming to rest -> {"still": frames at rest, "age": frames watched}.
var _settling: Dictionary = {}
# Server-only: crates frozen in the last few frames, still being re-sent -> [{body, left}].
var _pending_resend: Array = []
# Server-only: physics frames until the next _watch_stored.
var _watch_left: int = _WATCH_EVERY
# Server-only: frames left in the post-restore rebind window (see _rebind_stored_crates), 0 when idle.
var _rebind_left: int = 0

## Editor: dump this shelf in the NPC-service JSON schema to the output panel. The scenename is the
## scene file this node was saved in (works both when editing the shelf scene itself and on an
## instance placed in a level), without the res:// prefix; falls back to the metal shelf path when the
## node has no scene file (e.g. a script-built shelf).
func _export_to_npc_service() -> void:
	var scenename: String = scene_file_path.trim_prefix("res://")
	if scenename == "":
		scenename = "scenes/_universe/props/furniture/metal_shelf.tscn"
	# Hand-assembled so each slot stays a compact one-line [x, y, z] row (JSON.stringify with an indent
	# would explode every vector component onto its own line).
	var slot_lines: PackedStringArray = []
	for s in shelf_slots:
		slot_lines.append("    [%s, %s, %s]" % [
				JSON.stringify(s.x), JSON.stringify(s.y), JSON.stringify(s.z)])
	print("""{
  "_comment": "",
  "schema_version": 1,
  "scenename": %s,
  "object_type": "shelf",
  "front": [1.0, 0.0, 0.0],
  "slots": [
%s
  ]
}""" % [JSON.stringify(scenename), ",\n".join(slot_lines)])

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# Match the occupancy/body arrays to the authored slot count (the scene may leave them empty).
	if shelf_slots_occupied.size() != shelf_slots.size():
		shelf_slots_occupied.resize(shelf_slots.size())
		shelf_slots_occupied.fill(false)
	_slot_bodies.resize(shelf_slots.size())
	# So the drop logic (player_server._shelf_for_drop) can find every shelf by group.
	add_to_group("shelf")
	if GameOrchestrator.is_server():
		child_entered_tree.connect(_on_child_entered_tree)
	else:
		# Its tick is the server's (settling, rebinds): 165 shelves in the village called it 60 times a
		# second on every client to return at once.
		set_physics_process(false)
		child_entered_tree.connect(_client_on_child_entered_tree)
		child_exiting_tree.connect(_client_on_child_exiting_tree)

## Client: a stored crate is out of the physics space — body and interact area — unless the camera
## is within _REACH_M of it. The server owns every collision it takes part in; the client only needs
## it to be aimed at, and only within arm's reach. Measured 2026-10-23 in a depot stocked with 1 650
## crates (client.ini bisection, one switch at a time, same spot): 7 fps as shipped, the physics steps
## ~150 ms of each frame; 7 fps with the body's shape off, 17 with the interact area's off, 35 with
## both out of the space. Layer and mask 0 were not enough: at 8e10 m from the origin every query of
## a monitoring area (deposit zones, gravity spheres) walks every object in the space, whatever its
## layers. Removed through PhysicsServer3D, not process_mode, so the crate keeps processing (pose
## glide, landing watch); leaving the shelf (picked up) re-enters the tree, which puts it back.
func _client_on_child_entered_tree(node: Node) -> void:
	if not (node is CollisionObject3D) or _client_stored.has(node):
		return
	var body := node as CollisionObject3D
	_client_stored.append(body)
	body.set_meta(_META_IN_SPACE, true)  # entering the tree just put it there
	_client_set_in_space.call_deferred(body, false)  # deferred: its Area3D enters after this signal
	_client_dress(body, false, Vector3.ZERO)
	if not _client_reach_running:
		_client_reach_running = true
		_client_reach_loop.call_deferred()

func _client_on_child_exiting_tree(node: Node) -> void:
	if node is CollisionObject3D:
		_client_stored.erase(node)
		node.remove_meta(_META_IN_SPACE)  # exiting the tree takes it out; the next parent puts it back
		node.remove_meta(_META_DRESSED_NEAR)
		# Off the shelf, the scene's own settings rule again: every id frame (with its draw range),
		# every shadow.
		for label in _id_labels(node):
			label.visible = true
		for mesh in _shadow_meshes(node):
			if mesh.has_meta(_META_CAST_SHADOW):
				mesh.cast_shadow = mesh.get_meta(_META_CAST_SHADOW)
				mesh.remove_meta(_META_CAST_SHADOW)

## Client: put [param body] (a stored crate) and its interact area in their world's physics space, or
## take them out of it. No-op when it is already there / out, or no longer stored. Untyped: a deferred
## call can land after the crate was freed, and a typed parameter refuses a freed object.
static func _client_set_in_space(crate: Variant, inside: bool) -> void:
	if not is_instance_valid(crate):
		return
	var body := crate as CollisionObject3D
	if not body.is_inside_tree() or not body.has_meta(_META_IN_SPACE) \
			or bool(body.get_meta(_META_IN_SPACE)) == inside:
		return
	body.set_meta(_META_IN_SPACE, inside)
	var space: RID = body.get_world_3d().space if inside else RID()
	PhysicsServer3D.body_set_space(body.get_rid(), space)
	for area in body.find_children("*", "Area3D", false, false):
		PhysicsServer3D.area_set_space((area as Area3D).get_rid(), space)

## Client: the stored crates near the camera back in the physics space, the others out, every
## _REACH_EVERY_S, for the whole session (one loop for every shelf).
static func _client_reach_loop() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var reach_sq := _REACH_M * _REACH_M
	while true:
		await tree.create_timer(_REACH_EVERY_S).timeout
		var cam: Camera3D = tree.root.get_camera_3d()
		for i in range(_client_stored.size() - 1, -1, -1):
			var body := _client_stored[i]
			if not is_instance_valid(body):
				_client_stored.remove_at(i)
				continue
			var near: bool = cam != null \
					and body.global_position.distance_squared_to(cam.global_position) < reach_sq
			_client_set_in_space(body, near)
			if near or bool(body.get_meta(_META_DRESSED_NEAR, false)):
				_client_dress(body, near, cam.global_position if cam != null else Vector3.ZERO)

## The id frames (PropSerial.LABEL_GROUP) of the crate [param body], its direct children.
static func _id_labels(body: Node) -> Array[Label3D]:
	var out: Array[Label3D] = []
	for node in body.get_children():
		if node is Label3D and node.is_in_group(PropSerial.LABEL_GROUP):
			out.append(node)
	return out

## The meshes of the crate [param body] that may cast a shadow: every GeometryInstance3D under it but
## its id frames.
static func _shadow_meshes(body: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for node in body.find_children("*", "GeometryInstance3D", true, false):
		if not (node is Label3D):
			out.append(node)
	return out

## Client: dress the stored crate [param body] for the camera at [param eye], or for one far away
## when not [param near]. Looking down an aisle of a stocked depot the renderer handled 20 000-30 000
## objects, 13-17 ms of render CPU, against 5-6 ms facing a wall (2026-10-23):
## - its id frames: only those facing [param eye] (the eye on their front, +Z, side), and only near.
##   A crate prints its serial on five faces, 2 400 crates are 12 000 Label3D; hidden, an instance
##   leaves the renderer's culling structure, while one merely out of its draw range stays in it and
##   is re-placed with the rest every time the planet turns.
## - its shadow: only near. Inside a shelf a crate's shadow is barely seen, yet it is drawn again for
##   the sun's cascades and for every lamp of the depot whose range holds it.
static func _client_dress(body: Node3D, near: bool, eye: Vector3) -> void:
	for label in _id_labels(body):
		label.visible = near and (eye - label.global_position).dot(label.global_basis.z) > 0.0
	for mesh in _shadow_meshes(body):
		if not mesh.has_meta(_META_CAST_SHADOW):
			mesh.set_meta(_META_CAST_SHADOW, mesh.cast_shadow)
		mesh.cast_shadow = mesh.get_meta(_META_CAST_SHADOW) if near \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.set_meta(_META_DRESSED_NEAR, near)

## Server: settle the crates just stored or woken, watch the frozen ones, run the post-restore rebind
## window and re-send the poses of the crates just frozen.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not GameOrchestrator.is_server():
		return
	if _rebind_left > 0:
		_rebind_left -= 1
		if _rebind_left % _REBIND_EVERY == 0:
			_rebind_stored_crates(_rebind_left == 0)
	_watch_left -= 1
	if _watch_left <= 0:
		_watch_left = _WATCH_EVERY
		_watch_stored()
	if not _settling.is_empty():
		_settle_step()
	for i in range(_pending_resend.size() - 1, -1, -1):
		var e = _pending_resend[i]
		var body = e["body"]
		if not is_instance_valid(body) or body.get_parent() != self:
			_pending_resend.remove_at(i)
			continue
		if body.has_method("send_properties_to_client"):
			body.send_properties_to_client(uuid)
		e["left"] -= 1
		if e["left"] <= 0:
			_pending_resend.remove_at(i)

## True when a crate dropped at this WORLD point is close enough to a free slot to be stored here.
func can_store(world_point: Vector3) -> bool:
	return _nearest_free_slot(world_point) != -1

## Server: take [param body] onto the free slot nearest its WORLD position: under the shelf, set on the
## slot, aligned to the shelf, and dynamic so it settles onto its tier — frozen once it rests
## (_settle_step). False, and [param body] untouched, when no free slot is in range.
func store_at_nearest_slot(body: RigidBody3D) -> bool:
	var idx := _nearest_free_slot(body.global_position)
	if idx == -1:
		return false
	_put_on_slot(idx, body)
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze = false
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.can_sleep = true
	_settling[body] = {"still": 0, "age": 0}
	# The drop itself (new parent, slot pose) right away; the resting pose follows when it freezes.
	if body.has_method("send_properties_to_client"):
		body.send_properties_to_client(uuid)
	return true

## Server: reserve between one and all of the free slots, drawn at random from [param rng] — occupied,
## with no crate yet. The admin fill (CargoDepot.server_fill_shelves) spawns a crate on each one, under
## the shelf, and it binds its slot as it arrives (_bind_arrived). Empty when the shelf is full.
func reserve_random_slots(rng: RandomNumberGenerator) -> Array[int]:
	var free: Array[int] = []
	for i in range(mini(shelf_slots.size(), mini(shelf_slots_occupied.size(), _slot_bodies.size()))):
		if not shelf_slots_occupied[i] and typeof(_slot_bodies[i]) == TYPE_NIL:
			free.append(i)
	if free.is_empty():
		return free
	for i in range(free.size() - 1, 0, -1):  # Fisher-Yates on the given rng: a seed replays a fill
		var j := rng.randi_range(0, i)
		var swap := free[i]
		free[i] = free[j]
		free[j] = swap
	var picked: Array[int] = free.slice(0, rng.randi_range(1, free.size()))
	for i in picked:
		shelf_slots_occupied[i] = true
	_send_slots_occupied()
	return picked

## Server: [param body] is being taken off the shelf — the carry pickup, just before it reparents the
## crate to the player: free its slot. Same contract as Vehicle.release_cargo.
func release_cargo(body: Node) -> void:
	var idx := _slot_bodies.find(body)
	if idx != -1:
		_slot_bodies[idx] = null
		if idx < shelf_slots_occupied.size():
			shelf_slots_occupied[idx] = false
		_send_slots_occupied()
	_settling.erase(body)
	for i in range(_pending_resend.size() - 1, -1, -1):
		if _pending_resend[i]["body"] == body:
			_pending_resend.remove_at(i)

## Server -> Horizon: replicate the slot occupancy through the PropSync channel whenever it changes, so
## clients and a later server restart restore which slots are taken. _on_prop_update merges the key into
## the object's stored data, and it comes back inside object_data when Horizon re-creates the shelf (see
## apply_prop_data). PropSync.server_prop_update no-ops until the shelf is networked (uuid assigned).
func _send_slots_occupied() -> void:
	var s := PropSync.of(self)
	if s != null:
		s.server_prop_update({"shelf_slots_occupied": shelf_slots_occupied})

## PropSync applies the replicated transform, then hands us the rest of the payload — including the slot
## occupancy sent by _send_slots_occupied, and delivered again inside object_data when Horizon creates
## this shelf. Rebuild a typed bool array (the JSON round-trip returns an untyped Array).
func apply_prop_data(data: Dictionary) -> void:
	if "shelf_slots_occupied" in data:
		var occ: Array[bool] = []
		for v in data["shelf_slots_occupied"]:
			occ.append(bool(v))
		shelf_slots_occupied = occ
		if _slot_bodies.size() < shelf_slots_occupied.size():
			_slot_bodies.resize(shelf_slots_occupied.size())
		# Server after a restore: the crates bind as they arrive under the shelf (_bind_arrived). Open
		# the window that frees the slots whose crate never comes (no-op once every slot is bound).
		if GameOrchestrator.is_server():
			_rebind_left = _REBIND_FRAMES

## Reparent [param body] under the shelf if it is not there yet, bind it to slot [param idx] and set its
## origin on the slot, aligned to the shelf. Its freeze is the caller's business.
func _put_on_slot(idx: int, body: RigidBody3D) -> void:
	if body.get_parent() != self:
		if body.has_method("server_parent_change"):
			body.server_parent_change(self)  # a reparent, never reported as a deletion
		else:
			body.reparent(self)
	_bind(idx, body)
	body.transform = Transform3D(Basis.IDENTITY, shelf_slots[idx])

func _bind(idx: int, body: Node3D) -> void:
	_slot_bodies[idx] = body
	if idx < shelf_slots_occupied.size() and not shelf_slots_occupied[idx]:
		shelf_slots_occupied[idx] = true
		_send_slots_occupied()

## Freeze a stored crate where it rests and replicate that pose — a frozen body sends nothing by itself
## (PropNet.server_tick), so it is re-sent for a few frames against a lost packet.
func _freeze_stored(body: RigidBody3D) -> void:
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze = true
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	if body.has_method("send_properties_to_client"):
		body.send_properties_to_client(uuid)
	_pending_resend.append({"body": body, "left": _STORE_RESEND_FRAMES})

## Per physics frame while crates are settling: freeze each one once it has rested _SETTLE_FRAMES in a
## row (or after _SETTLE_TIMEOUT_FRAMES). One frozen meanwhile by someone else (a zone freeze, a ground
## hold) is left to them: _watch_stored picks it up again when it wakes.
func _settle_step() -> void:
	for body in _settling.keys():
		if not is_instance_valid(body) or body.get_parent() != self or body.freeze:
			_settling.erase(body)
			continue
		var rb := body as RigidBody3D
		var st: Dictionary = _settling[body]
		st["age"] += 1
		if rb.sleeping or (rb.linear_velocity.length() < _SETTLE_LINEAR
				and rb.angular_velocity.length() < _SETTLE_ANGULAR):
			st["still"] += 1
		else:
			st["still"] = 0
		if st["still"] >= _SETTLE_FRAMES or st["age"] >= _SETTLE_TIMEOUT_FRAMES:
			_settling.erase(body)
			_freeze_stored(rb)

## Every _WATCH_EVERY frames: a stored crate somebody else made dynamic again (the settle-culler near a
## player, a zone hand-over, a ground hold released) settles and freezes once more. A slot whose crate
## is gone (freed, or taken elsewhere without release_cargo) is freed.
func _watch_stored() -> void:
	var freed := false
	for i in range(_slot_bodies.size()):
		var body = _slot_bodies[i]
		if typeof(body) == TYPE_NIL:
			continue  # unbound (a freed crate is NOT this: it still holds an Object, but reads == null)
		if not is_instance_valid(body) or body.get_parent() != self:
			_slot_bodies[i] = null
			if i < shelf_slots_occupied.size() and shelf_slots_occupied[i]:
				shelf_slots_occupied[i] = false
				freed = true
			continue
		if body is RigidBody3D and not body.freeze and not _settling.has(body):
			_settling[body] = {"still": 0, "age": 0}
	if freed:
		_send_slots_occupied()

func _on_child_entered_tree(node: Node) -> void:
	if node is RigidBody3D:
		_bind_arrived.call_deferred(node)  # deferred: its position and its _ready come after this signal

## Server: a crate created under the shelf (restart, hand-over, the shelf waking up with its chunk)
## takes the slot it stands on, and settles there if nothing keeps it frozen.
func _bind_arrived(body: Variant) -> void:
	if not is_instance_valid(body) or not (body is RigidBody3D) or body.get_parent() != self \
			or _slot_bodies.has(body):
		return
	var idx := _nearest_unbound_slot((body as RigidBody3D).position)
	if idx == -1:
		return
	_bind(idx, body)
	if not body.freeze:
		_settling[body] = {"still": 0, "age": 0}

## Server: free the occupied slots that no crate came back to bind, so they are not leaked forever.
## Retried across the rebind window. A crate stored before crates were parented to their shelf is a
## world prop resting on its slot: it is taken under the shelf and set back on the slot (which also
## puts back the crates of that era that fell through on a hand-over). On the [param last] attempt,
## slots still without a crate are freed — their crate no longer exists.
func _rebind_stored_crates(last: bool) -> void:
	var all_bound := true
	for i in range(mini(shelf_slots.size(), shelf_slots_occupied.size())):
		if not shelf_slots_occupied[i] or _slot_bodies[i] != null:
			continue
		var body := _world_crate_near_slot(i)
		if body == null:
			all_bound = false
			continue
		_put_on_slot(i, body)
		if not body.freeze:
			_settling[body] = {"still": 0, "age": 0}
		elif body.has_method("send_properties_to_client"):
			body.send_properties_to_client(uuid)  # frozen: PropNet.server_tick would not send the new parent
	if all_bound:
		_rebind_left = 0
	elif last:
		var freed := false
		for i in range(mini(shelf_slots.size(), shelf_slots_occupied.size())):
			if shelf_slots_occupied[i] and _slot_bodies[i] == null:
				shelf_slots_occupied[i] = false
				freed = true
		if freed:
			_send_slots_occupied()

## The nearest carriable resting in the WORLD (not on a shelf, not carried or riding) whose centre is
## within snap range of slot [param idx], or null. See _rebind_stored_crates.
func _world_crate_near_slot(idx: int) -> RigidBody3D:
	var slot_pos := to_global(shelf_slots[idx])
	var best: RigidBody3D = null
	var best_d := SLOT_SNAP_RANGE * SLOT_SNAP_RANGE
	for c in get_tree().get_nodes_in_group("carriable"):
		if not (c is RigidBody3D) or c.get_parent() is Shelf or PropNet.rides_parent(c):
			continue
		var sync := PropSync.of(c)
		if sync != null and sync.carried:
			continue
		var d: float = (c as RigidBody3D).global_position.distance_squared_to(slot_pos)
		if d < best_d:
			best_d = d
			best = c
	return best

## Index of the free slot whose WORLD position is nearest [world_point] within SLOT_SNAP_RANGE, or -1.
func _nearest_free_slot(world_point: Vector3) -> int:
	var best := -1
	var best_d := SLOT_SNAP_RANGE * SLOT_SNAP_RANGE
	for i in range(shelf_slots.size()):
		if i < shelf_slots_occupied.size() and shelf_slots_occupied[i]:
			continue
		var d := to_global(shelf_slots[i]).distance_squared_to(world_point)
		if d < best_d:
			best_d = d
			best = i
	return best

## Index of the slot without a bound crate nearest the shelf-LOCAL point [param local_point] within
## SLOT_SNAP_RANGE, or -1. Occupied or not: a crate coming back restores the occupancy it had.
func _nearest_unbound_slot(local_point: Vector3) -> int:
	var best := -1
	var best_d := SLOT_SNAP_RANGE * SLOT_SNAP_RANGE
	for i in range(mini(shelf_slots.size(), _slot_bodies.size())):
		if _slot_bodies[i] != null:
			continue
		var d := shelf_slots[i].distance_squared_to(local_point)
		if d < best_d:
			best_d = d
			best = i
	return best
