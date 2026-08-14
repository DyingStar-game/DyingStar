@tool
extends Node3D

## Networked cargo depot structure. NOT a GenericProp: that base is the RigidBody3D facade for
## carriable props, and this body is a plain Node3D (structures follow spawn_building/mining_depot:
## keep the PropSync child for networking and inline the tiny uuid facade below). Custom state
## (reception_players, storage_shelves) is applied via apply_prop_data().

@export_group("PNJ")

@export var is_pnj_workplace: bool = false

# Scanned from the scene tree: { category: { area_name: { position, size, path } } }.
# Category comes from each PNJPlace* Area3D "editor_description" field.
@export var pnj_zones: Dictionary = {}

# Resolved through a getter, not an initializer, so the editor can never read the button
# callback back as Nil ("value is Nil, but Callable was expected").
@export_tool_button("Scan PNJ zones")
var _scan_pnj_zones_action: Callable:
	get: return scan_pnj_zones

@export_tool_button("Convert to JSON")
var _pnj_zones_to_json_action: Callable:
	get: return pnj_zones_to_json

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

# is there a player in reception area?
var reception_players: Array = []

# uuid of the single PNJ (magasinier) that currently owns the reception role at
# this depot, or "" when free. Server-authoritative and race-free (the Godot
# game server is single-threaded): a PNJ takes reception by CLAIMING it, the
# others read this to know they must stock the shelves instead. Replicated to
# every subscriber (including the PNJ brains in the npc service) via
# _send_reception_owner, and cleared when the owner releases it or disconnects.
var reception_owner: String = ""

# list boxes in the shelves
var storage_shelves: Array = []

# Distance max a PNJ can view a player in the reception area (in meters)
var max_distance_to_reception: float = 5.0

# We store the node when object deposited in reception area
var pnj_reception_deposited_item: Array = []

var pnj_box_temp_zones = {}

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# @tool script: nothing of the runtime prop logic must run inside the editor.
	if Engine.is_editor_hint():
		set_process(false)
		set_physics_process(false)
		return
	# Server-side registry so the player-removal path can clear a disconnected PNJ's reception claim
	# without knowing where depots are spawned in the tree (see server.gd::remove_player).
	if GameOrchestrator.is_server():
		add_to_group("cargo_depots")
		# Seed the zone contents from what is ALREADY sitting there. `body_entered` is edge-triggered,
		# so crates restored from persistence (or dropped while the filter below was rejecting them)
		# would otherwise stay invisible to the magasiniers forever: the property would say the temp
		# zone is empty while it is visibly full. Deferred by two physics frames because overlaps are
		# only resolved once the bodies have been added to the space.
		_seed_zone_contents.call_deferred()
	# DIAGNOSTIC: confirm the depot exists on the server and its reception_area is monitoring.
	var _ra := get_node_or_null("reception_area")
	print("[cargo_depot] _ready on %s  reception_area=%s monitoring=%s mask=%s" % [
		"server" if GameOrchestrator.is_server() else "client",
		_ra, ("?" if _ra == null else str(_ra.monitoring)), ("?" if _ra == null else str(_ra.collision_mask))])

# _enter_tree / _exit_tree no longer needed: the networking they used to forward (server_reparenting
# guard + delete emit) now lives entirely in the PropSync child, which is inert in the editor on its own.


## Editor button: walk the scene tree, collect every Area3D whose name starts with
## "PNJPlace", and group them by their "editor_description" (the category).
## Position and size are expressed in this node's local space.
func scan_pnj_zones() -> void:
	var zones: Dictionary = {}
	var found := 0
	var root_inv := global_transform.affine_inverse()

	for area in find_children("PNJPlace*", "Area3D", true, false):
		var category: String = area.editor_description.strip_edges()
		if category.is_empty():
			push_warning("PNJ zone '%s' has no editor_description (category), skipped." % area.name)
			continue

		var shape := _find_collision_shape(area)
		if shape == null or shape.shape == null:
			push_warning("PNJ zone '%s' has no CollisionShape3D with a shape, skipped." % area.name)
			continue

		var local := root_inv * shape.global_transform
		if not zones.has(category):
			zones[category] = {}
		var entry := {
			"position": snapped(local.origin, Vector3(0.001, 0.001, 0.001)),
			"size": snapped(_shape_size(shape.shape) * shape.global_transform.basis.get_scale(), Vector3(0.001, 0.001, 0.001)),
			"path": get_path_to(area),
		}

		# Sibling deposit zone (same parent as the PNJPlace* area): where the PNJ must drop the box.
		var deposit := area.get_parent().get_node_or_null("PNJBoxDepositTempZone") as Area3D
		if deposit != null:
			var deposit_shape := _find_collision_shape(deposit)
			if deposit_shape != null and deposit_shape.shape != null:
				entry["target"] = snapped((root_inv * deposit_shape.global_transform).origin, Vector3(0.001, 0.001, 0.001))

		zones[category][String(area.name)] = entry
		found += 1

	pnj_zones = zones
	notify_property_list_changed()
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()
	print("[cargo_depot] scanned %d PNJ zone(s) in %d categorie(s): %s"
		% [found, zones.size(), ", ".join(PackedStringArray(zones.keys()))])


## Editor button: serialize `pnj_zones` to JSON and print it to the output.
## Vector3 positions/sizes and NodePath values aren't JSON-native, so they're
## converted to plain arrays/strings first.
func pnj_zones_to_json() -> void:
	var json := JSON.stringify(_json_safe(pnj_zones), "\t")
	print("[cargo_depot] pnj_zones as JSON:\n%s" % json)


## Recursively convert a value into something JSON.stringify accepts:
## Vector3 -> [x, y, z], NodePath -> String, and Dictionary/Array walked in place.
func _json_safe(value: Variant) -> Variant:
	if value is Dictionary:
		var out := {}
		for key in value:
			out[String(key)] = _json_safe(value[key])
		return out
	if value is Array:
		var out := []
		for item in value:
			out.append(_json_safe(item))
		return out
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is NodePath:
		return String(value)
	return value


func _find_collision_shape(area: Area3D) -> CollisionShape3D:
	for child in area.get_children():
		if child is CollisionShape3D:
			return child
	return null


func _shape_size(shape: Shape3D) -> Vector3:
	if shape is BoxShape3D:
		return shape.size
	if shape is SphereShape3D:
		return Vector3.ONE * shape.radius * 2.0
	if shape is CylinderShape3D:
		return Vector3(shape.radius * 2.0, shape.height, shape.radius * 2.0)
	if shape is CapsuleShape3D:
		return Vector3(shape.radius * 2.0, shape.height, shape.radius * 2.0)
	# Fallback for arbitrary shapes (convex/concave/…).
	return shape.get_debug_mesh().get_aabb().size


## PropSync applies the replicated transform, then calls this with the full payload so the depot can
## pick up its own (non-transform) fields. Replaces the old client_channel_data_update override.
func apply_prop_data(data: Dictionary) -> void:
	if "reception_players" in data:
		reception_players = data["reception_players"]

	if "reception_owner" in data:
		reception_owner = data["reception_owner"]

	if "storage_shelves" in data:
		storage_shelves = data["storage_shelves"]


## Server-authoritative: a PNJ asks to take the reception role. Granted only when nobody owns it
## (single-threaded server, so this read-check-set is atomic). Returns true when this PNJ is the
## owner afterwards (freshly granted or it already held it), false when someone else owns it.
func try_claim_reception(player_uuid: String) -> bool:
	if not GameOrchestrator.is_server():
		return false
	if reception_owner == player_uuid:
		return true
	if reception_owner != "":
		return false
	reception_owner = player_uuid
	print("[cargo_depot] reception claimed by %s" % player_uuid)
	_send_reception_owner()
	return true


## Server-authoritative: the owning PNJ hands the reception role back (going off-shift, to a meal…).
## No-op unless the caller is the current owner, so a stale release can never free someone else's claim.
func release_reception(player_uuid: String) -> void:
	if not GameOrchestrator.is_server():
		return
	if reception_owner == player_uuid:
		reception_owner = ""
		print("[cargo_depot] reception released by %s" % player_uuid)
		_send_reception_owner()


## Server-authoritative backstop: clear the claim if `player_uuid` currently holds it (called from
## the player-removal path when a PNJ disconnects, so the role never stays stuck on a gone owner).
func clear_reception_owner_if(player_uuid: String) -> void:
	if not GameOrchestrator.is_server():
		return
	if reception_owner == player_uuid:
		reception_owner = ""
		print("[cargo_depot] reception owner %s left; clearing claim" % player_uuid)
		_send_reception_owner()

func _on_reception_area_body_entered(body: Node3D) -> void:
	# Server-authoritative: only the server owns reception_players; clients receive it through
	# apply_prop_data. Mutating it client-side would just be overwritten by the next replication.
	if not GameOrchestrator.is_server():
		return
	print("[cargo_depot] player %s entered reception area" % body.client_uuid)
	reception_players.append(body.client_uuid)
	_send_reception_players()


func _on_reception_area_body_exited(body: Node3D) -> void:
	if not GameOrchestrator.is_server():
		return
	reception_players.erase(body.client_uuid)
	_send_reception_players()

## Rebuild `pnj_box_temp_zones` and `pnj_reception_deposited_item` from the bodies currently
## overlapping each area, and replicate the result. Idempotent, so it is safe to call again.
##
## The two dictionaries are otherwise only ever maintained by `body_entered` / `body_exited`, which
## say nothing about a world that was already populated when the depot spawned. Every crate restored
## from persistence into the temp zone falls in that gap.
func _seed_zone_contents() -> void:
	if not GameOrchestrator.is_server():
		return
	# Two frames: one for this deferred call to land, one for the physics server to have resolved the
	# overlaps of bodies added alongside us. get_overlapping_bodies() reads the LAST step's result.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree():
		return

	var zones := {}
	var temp_root := get_node_or_null("TempZone")
	if temp_root != null:
		for place in temp_root.get_children():
			# "Place5" -> zone_5, the same index the scene binds to the signals and the same key the
			# npc service derives from its "PNJPlace5" zone name.
			var place_name := String(place.name)
			if not place_name.begins_with("Place"):
				continue
			var digits := place_name.substr(5)
			if not digits.is_valid_int():
				continue
			var area := place.get_node_or_null("PNJBoxDepositTempZone") as Area3D
			if area == null:
				continue
			var found: Array = []
			for body in area.get_overlapping_bodies():
				var id := _box_uuid(body)
				if id != "":
					found.append(id)
			if not found.is_empty():
				zones["zone_" + digits] = found
	if zones != pnj_box_temp_zones:
		pnj_box_temp_zones = zones
		_send_pnj_box_temp_zones()

	var counter := get_node_or_null("ReceptionDesk/PNJBoxDepositPlayer") as Area3D
	if counter != null:
		var on_counter: Array = []
		for body in counter.get_overlapping_bodies():
			var id := _box_uuid(body)
			if id != "":
				on_counter.append(id)
		if on_counter != pnj_reception_deposited_item:
			pnj_reception_deposited_item = on_counter
			_send_reception_deposited_item()
	print("[cargo_depot] seeded zones=%s counter=%s" % [pnj_box_temp_zones, pnj_reception_deposited_item])


## Networked uuid of `body` if it is a prop a magasinier can pick up and shelve — what the depot flow
## calls "a box" — or "" for anything else. The single gate for both zones.
##
## Deliberately NOT `type_name == "box"`, which the temp zone used to test. That key does not mean
## "carriable container": the 19 scenes carrying it are the PALLETS and fixed containers, every one of
## them `enable_carry = false`, while the crate the magasiniers are configured to handle
## (hauling_box.tscn, `boxes_type_allowed` in the npc service's npcs.yaml) is
## `type_name = "crate_container"`. The test therefore accepted only props an NPC cannot lift and
## rejected the only one it can: the temp zone stayed empty forever and the stocker never came for it.
## `enable_carry` is the property that states the intent; the npc service still does the fine-grained
## `scenename` check on top.
##
## Returning the uuid (rather than a bool) also keeps `uuid` read off the PropSync child, which every
## networked prop has, instead of off the body, which is a facade only some scenes define.
func _box_uuid(body: Node) -> String:
	var sync := PropSync.of(body)
	if sync == null or not sync.enable_carry or sync.uuid == "":
		return ""
	return sync.uuid


func _on_box_counter_body_entered(body: Node3D) -> void:
	if not GameOrchestrator.is_server():
		return
	# Same gate as the temp zone: the counter used to append `body.uuid` for ANY body the area's mask
	# let through, which listed props no magasinier could lift and read `uuid` off bodies that may not
	# expose it at all.
	var id := _box_uuid(body)
	if id == "" or pnj_reception_deposited_item.has(id):
		return
	pnj_reception_deposited_item.append(id)
	_send_reception_deposited_item()


func _on_box_counter_body_exited(body: Node3D) -> void:
	if not GameOrchestrator.is_server():
		return
	var id := _box_uuid(body)
	if id == "" or not pnj_reception_deposited_item.has(id):
		return
	pnj_reception_deposited_item.erase(id)
	_send_reception_deposited_item()

# when a box enter in the temporary zone, we store it in a dictionary with the zone id as key
func _on_pnj_box_deposit_temp_zone_body_entered(body: Node3D, extra_arg_0: int) -> void:
	if not GameOrchestrator.is_server():
		return
	var id := _box_uuid(body)
	if id == "":
		return
	var key := "zone_" + str(extra_arg_0)
	if not pnj_box_temp_zones.has(key):
		pnj_box_temp_zones[key] = []
	# The seed pass may already have listed it (both run at spawn): never double-list, or removing it
	# once would leave a phantom the stocker keeps walking to.
	if pnj_box_temp_zones[key].has(id):
		return
	pnj_box_temp_zones[key].append(id)
	_send_pnj_box_temp_zones()

# when a box exit the temporary zone, we remove it from the dictionary with the zone id as key
func _on_pnj_box_deposit_temp_zone_body_exited(body: Node3D, extra_arg_0: int) -> void:
	if not GameOrchestrator.is_server():
		return
	var id := _box_uuid(body)
	if id != "":
		if pnj_box_temp_zones.has("zone_" + str(extra_arg_0)):
			pnj_box_temp_zones["zone_" + str(extra_arg_0)].erase(id)
			_send_pnj_box_temp_zones()


#------ funtions to send variable to horizon on server side ------#

## Replicate the reception_players list to clients through the PropSync channel (consumed by
## apply_prop_data). No-op until the depot is networked (uuid assigned) — see server_prop_update.
func _send_reception_players() -> void:
	if _sync != null:
		_sync.server_prop_update({"reception_players": reception_players})

func _send_reception_owner() -> void:
	if _sync != null:
		_sync.server_prop_update({"reception_owner": reception_owner})

func _send_reception_deposited_item() -> void:
	if _sync != null:
		_sync.server_prop_update({"pnj_reception_deposited_item": pnj_reception_deposited_item})

func _send_pnj_box_temp_zones() -> void:
	if _sync != null:
		_sync.server_prop_update({"pnj_box_temp_zones": pnj_box_temp_zones})
