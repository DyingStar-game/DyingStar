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
