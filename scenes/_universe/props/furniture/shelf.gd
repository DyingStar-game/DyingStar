@tool
extends StaticBody3D

## A shelf with a grid of discrete storage SLOTS. A carried crate dropped near a free slot snaps onto
## it and freezes there (server-authoritative); picking it back up frees the slot again. Mirrors the
## truck cargo-bed contract (Vehicle.lock_dropped_cargo / release_cargo) but, because a shelf never
## moves, the stored crate stays a NORMAL resting world prop (frozen at the slot's WORLD pose) instead
## of being reparented under the shelf — so its replication rides the ordinary settled-prop path and
## needs no assumption about the shelf being a networked-parentable prop. The shelf only owns the
## slot bookkeeping; the crate remembers which shelf/slot it sits in via meta so a later pickup (in
## player_server.gd) can free the slot.

@export_group("Shelf")
@export var shelf_name: String = "Shelf"
@export var shelf_tiers: int = 10
@export var shelf_horizontal_capacity: int = 10
## Local (shelf-space) positions of every slot; authored in the scene.
@export var shelf_slots: Array[Vector3] = []
## Editor button: print this shelf as the JSON block the NPC service consumes (scenename + slots).
@export_tool_button("export to NPC service") var _export_npc_service = _export_to_npc_service
## Per-slot occupancy, parallel to shelf_slots. Initialised in _ready if left empty in the scene.
@export var shelf_slots_occupied: Array[bool] = []

## How far a dropped crate's centre may be from a free slot for that slot to swallow it (metres).
const SLOT_SNAP_RANGE := 2.0
## How many physics frames to keep re-sending a just-stored crate's resting pose, so a single lost
## packet can't strand its replica where it was grabbed (the frozen body won't resend on its own).
const _STORE_RESEND_FRAMES := 15
## Retry window (physics frames) to re-link restored crates to occupied slots after a restart, and
## how often to retry within it — the shelf and its crates arrive from Horizon in any order.
const _REBIND_FRAMES := 600
const _REBIND_EVERY := 30

# Server-only: the crate body occupying each slot (parallel to shelf_slots), null when free.
var _slot_bodies: Array = []
# Server-only: crates stored in the last few frames, still being re-sent -> [{body, parent_uuid, left}].
var _pending_resend: Array = []
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

## Server: re-assert a just-stored crate's resting pose for a few frames (cheap loss insurance),
## and run the post-restore rebind retry loop.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not GameOrchestrator.is_server():
		return
	if _rebind_left > 0:
		_rebind_left -= 1
		if _rebind_left % _REBIND_EVERY == 0:
			_rebind_stored_crates(_rebind_left == 0)
	if _pending_resend.is_empty():
		return
	for i in range(_pending_resend.size() - 1, -1, -1):
		var e = _pending_resend[i]
		var body = e["body"]
		if not is_instance_valid(body):
			_pending_resend.remove_at(i)
			continue
		if body.has_method("send_properties_to_client"):
			body.send_properties_to_client(e["parent_uuid"])
		e["left"] -= 1
		if e["left"] <= 0:
			_pending_resend.remove_at(i)

## True when a crate dropped at this WORLD point is close enough to a free slot to be stored here.
func can_store(world_point: Vector3) -> bool:
	return _nearest_free_slot(world_point) != -1

## Server: snap [body] onto the nearest free slot (its WORLD pose), freeze it there and mark the slot
## taken. The caller has already reparented the crate out of the player and into the world node whose
## uuid is [parent_uuid] (used to replicate the resting pose). No-op if no free slot is in range.
func store_at_nearest_slot(body: Node3D, parent_uuid: String) -> void:
	var idx := _nearest_free_slot(body.global_position)
	if idx == -1:
		return
	_slot_bodies[idx] = body
	shelf_slots_occupied[idx] = true
	_send_slots_occupied()
	body.set_meta("shelf_ref", self)
	body.set_meta("shelf_slot", idx)
	# Place the crate's geometric CENTRE on the slot, aligned to the shelf.
	body.global_rotation = global_rotation
	var center: Vector3 = body.get_center_offset() if body.has_method("get_center_offset") else Vector3.ZERO
	body.global_position = to_global(shelf_slots[idx]) - body.global_basis * center
	# Freeze it in place as a normal resting world prop (the shelf never moves -> STATIC is correct).
	if body is RigidBody3D:
		body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	# Replicate the resting pose now, then re-send it for a few frames against packet loss.
	if body.has_method("send_properties_to_client"):
		body.send_properties_to_client(parent_uuid)
	_pending_resend.append({"body": body, "parent_uuid": parent_uuid, "left": _STORE_RESEND_FRAMES})

## Server: free the slot [body] occupies (called from the carry pickup path when a stored crate is
## grabbed). Clears the crate's shelf meta so it is a plain carriable again.
func release_slot(body: Node3D) -> void:
	var idx := _slot_bodies.find(body)
	if idx != -1:
		_slot_bodies[idx] = null
		shelf_slots_occupied[idx] = false
		_send_slots_occupied()
	for i in range(_pending_resend.size() - 1, -1, -1):
		if _pending_resend[i]["body"] == body:
			_pending_resend.remove_at(i)
	if body.has_meta("shelf_ref"):
		body.remove_meta("shelf_ref")
	if body.has_meta("shelf_slot"):
		body.remove_meta("shelf_slot")

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
		# Server after a restart: the occupancy came back but _slot_bodies and the crates' shelf meta
		# did not (meta isn't replicated) — without them a pickup would never free its slot. Open the
		# rebind window; a no-op when every occupied slot already has its body (normal play).
		if GameOrchestrator.is_server():
			_rebind_left = _REBIND_FRAMES

## Server: re-link every occupied-but-unbound slot to the restored crate resting on it, so the
## pickup path (player_server.gd, via the crate's shelf meta) can free the slot again. Retried
## across the rebind window because the shelf and its crates arrive from Horizon in any order; on
## the [param last] attempt, slots still without a crate are freed — their crate no longer exists,
## and keeping them occupied would leak the slot forever.
func _rebind_stored_crates(last: bool) -> void:
	var all_bound := true
	for i in range(mini(shelf_slots.size(), shelf_slots_occupied.size())):
		if not shelf_slots_occupied[i] or _slot_bodies[i] != null:
			continue
		var body := _crate_resting_on_slot(i)
		if body == null:
			all_bound = false
			continue
		_slot_bodies[i] = body
		body.set_meta("shelf_ref", self)
		body.set_meta("shelf_slot", i)
		# Same resting state store_at_nearest_slot leaves the crate in (freeze isn't persisted).
		if body is RigidBody3D:
			body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			body.freeze = true
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO
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

## The nearest unbound, uncarried carriable whose geometric centre rests within snap range of slot
## [param idx], or null. Mirrors the store placement (centre on the slot) so restored crates match.
func _crate_resting_on_slot(idx: int) -> Node3D:
	var slot_pos := to_global(shelf_slots[idx])
	var best: Node3D = null
	var best_d := SLOT_SNAP_RANGE * SLOT_SNAP_RANGE
	for c in get_tree().get_nodes_in_group("carriable"):
		if not (c is Node3D) or c.has_meta("shelf_ref"):
			continue
		var sync := PropSync.of(c)
		if sync != null and sync.carried:
			continue
		var center: Vector3 = c.get_center_offset() if c.has_method("get_center_offset") else Vector3.ZERO
		var d: float = (c.global_position + c.global_basis * center).distance_squared_to(slot_pos)
		if d < best_d:
			best_d = d
			best = c
	return best

## Index of the free slot whose WORLD position is nearest [world_point] within SLOT_SNAP_RANGE, or -1.
func _nearest_free_slot(world_point: Vector3) -> int:
	var best := -1
	var best_d := SLOT_SNAP_RANGE * SLOT_SNAP_RANGE
	var num := 0
	for i in range(shelf_slots.size()):
		if i < shelf_slots_occupied.size() and shelf_slots_occupied[i]:
			continue
		num += 1
		var d := to_global(shelf_slots[i]).distance_squared_to(world_point)
		#print(d)
		if d < best_d:
			best_d = d
			best = i
	print(global_position)
	print(world_point)
	return best
