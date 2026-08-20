extends StaticBody3D

## Networked mining depot. Networking (uuid, replication, reparent, delete) lives in the PropSync child
## node (type_name "mining_depot", non-carriable); machine state is applied via apply_prop_data(), and
## server-side state updates go out via server_prop_update() which forwards to the PropSync component.

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## The crate the depot packs its ore into. It replicates as the "crate_container" TYPE (that def is
## the one whose channels carry `content`, the ore volume) — only the scene differs. Its physical size
## is what crate_volume() reads to decide how much ore fills one crate.
const CRATE_SCENE = preload("res://scenes/_universe/props/containers/hauling_box.tscn")
const CRATE_SCENENAME = "scenes/_universe/props/containers/hauling_box.tscn"
@export var placeholder = false
## Optional explicit network id for a designer-placed depot. Leave EMPTY and it is derived
## automatically from the depot's fixed position (stable across restarts, no setup needed).
## Set a unique string only if you want a readable id or to keep identity when moving it.
@export var stable_id: String = ""

var type_name = "mining_depot"  # kept for the placeholder self-spawn; PropSync carries the networked copy
var state := "idle"

var _sync: PropSync

## Cached PropSync child, resolved lazily so a facade access before _ready still works.
func _prop_sync() -> PropSync:
	if _sync == null:
		_sync = PropSync.of(self)
	return _sync

var uuid: String:
	get:
		var s := _prop_sync()
		return s.uuid if s != null else ""
	set(value):
		var s := _prop_sync()
		if s != null:
			s.uuid = value
var rocks_on_conveyor := 0
# Refining stats (volumes in m3). rock_volume = total rock processed; ore_volume = total
# ore obtained from it; extracted_volume = ore already packed into crates. Available ore
# left to pack into a new crate = ore_volume - extracted_volume.
var rock_volume := 0.0
var ore_volume := 0.0
var extracted_volume := 0.0
# Volume of rock + ore currently on the input conveyor (live preview for SEND).
var conveyor_rock_volume := 0.0
var conveyor_ore_volume := 0.0
var active_player: Player

# Throttle: only replicate the depot state when it actually changes.
var _last_sent_conveyor := -1
var _last_sent_state := ""
var _last_sent_ore := -1.0
var _last_sent_extracted := -1.0
var _last_sent_conv := -1.0
# Cached fillable volume of one crate (crate_container), read from its scene.
var _crate_volume := -1.0

@onready var rock_depot_ui: Panel = %RockDepotUI
@onready var danger_light_collect: Node3D = $DangerLightCollect
@onready var rock_conveyor: MeshInstance3D = $miningdepot/conveyorbelt_001
@onready var rock_detector: Area3D = $RockDetector
@onready var rock_collector: Area3D = $RockCollector
@onready var box_spawn_origin: Marker3D = $BoxSpawnOrigin
@onready var box_conveyorbelt: MeshInstance3D = $miningdepot/conveyorbelt_003
@onready var danger_light_box: Node3D = $DangerLightBox
@onready var box_detector: Area3D = $BoxDetector
@onready var box_detector_end: Area3D = $BoxDetectorEnd

func _ready() -> void:
	if placeholder:
		if GameOrchestrator.is_server():
			await get_tree().create_timer(1).timeout
			var parent = get_parent()
			# Find the real networked parent up the tree (skip grouping / test-zone folder nodes
			# that have no uuid), so grouping the placeholder under a folder doesn't break placement.
			var net_parent: Node = parent
			while net_parent != null and not ("uuid" in net_parent):
				net_parent = net_parent.get_parent()
			var parent_uuid: String = str(net_parent.uuid) if net_parent != null else ""
			# Express the placement in that parent's frame (global if there is no networked parent),
			# so the depot lands at the SAME world spot whatever the scene grouping.
			var place_xform: Transform3D = global_transform
			if net_parent is Node3D:
				place_xform = (net_parent as Node3D).global_transform.affine_inverse() * global_transform
			var place_pos: Vector3 = place_xform.origin
			var place_rot: Vector3 = place_xform.basis.get_euler()

			# Spawn the real networked depot to replace this editor placeholder. Use
			# spawn_prop_authoritative so it is registered in Horizon AND created locally on
			# this game server (the server copy is what holds the collision and the detectors
			# / collect / SEND logic). Sending only to Horizon would leave the server without
			# a depot node, since Horizon does not echo create_object back.
			# Deterministic, VALID-format uuid so this depot is always the SAME object across
			# restarts (the database upserts by uuid -> no duplicate pile-up, and no delete is
			# needed). Seed from the explicit stable_id, else from the fixed placement position
			# so no manual setup is required.
			# Seed from the STABLE local placement (parent frame) + parent uuid, NOT global_position:
			# the parent is a moving world frame, so global_position differs every restart -> a new
			# uuid each time -> the DB (upsert by uuid) never dedups -> depots pile up. place_pos is
			# fixed in the parent's frame, so the same depot keeps the same uuid across restarts.
			var uuid_seed: String = stable_id if stable_id != "" \
				else "%s|%.3f,%.3f,%.3f" % [parent_uuid, place_pos.x, place_pos.y, place_pos.z]
			var depot_uuid: String = _stable_uuid(uuid_seed)
			# Designer-placed depot = world infrastructure: protect it from the admin cleanup
			# tool (only player-spawned depots should be deletable).
			NetworkOrchestrator.protected_prop_uuids[depot_uuid] = true
			NetworkOrchestrator.spawn_prop_authoritative({
				"type": type_name,
				"uuid": depot_uuid,
				"position": {
					"x": place_pos.x,
					"y": place_pos.y,
					"z": place_pos.z
				},
				"rotation": {
					"x": place_rot.x,
					"y": place_rot.y,
					"z": place_rot.z
				},
				"data": {
					"state": "idle",
					"rocks_on_conveyor": 0,
					"rock_volume": 0.0,
					"ore_volume": 0.0,
					"extracted_volume": 0.0,
					"active_player": null
				},
				"scenename": "scenes/_universe/structures/industrial/mines/mining_depot.tscn",
				"parent_id": parent_uuid,
			})

		queue_free()
		return  # placeholder is done; don't wire detectors on the node we just freed

	if GameOrchestrator.is_server():
		if box_detector != null:
			box_detector.body_exited.connect(box_exited)
		else:
			push_warning("[mining_depot] $BoxDetector missing, skipped body_exited connect")
		if rock_detector != null:
			rock_detector.body_exited.connect(_on_rock_exited)
		else:
			push_warning("[mining_depot] $RockDetector missing, skipped body_exited connect")

## Build a deterministic, valid-format uuid from a seed string. Same seed -> same uuid
## across restarts, so the depot is upserted (not duplicated) and Horizon can resolve it.
func _stable_uuid(uuid_seed: String) -> String:
	var h: String = uuid_seed.sha256_text()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]

## In collect mode, a rock that slides off the conveyor end (leaves the detector) is
## collected. Skip rocks a player just picked up (carried) so grabbing one off the belt
## doesn't count it.
func _on_rock_exited(body: Node3D) -> void:
	if not GameOrchestrator.is_server() or state != "collect":
		return
	if not body.is_in_group("miningrock"):
		return
	if "carried" in body and body.carried:
		return
	_collect_rock(body)

func _process(_delta: float) -> void:
	if GameOrchestrator.is_server():
		var conveyor_rocks = get_rocks_on_conveyor()
		var collect_rocks = get_rocks_to_collect()

		for rock in collect_rocks:
			_collect_rock(rock)

		if state == "collect":
			var desired_velocity = -rock_detector.global_basis.z * 2
			# move rocks on conveyor
			for rock: RigidBody3D in conveyor_rocks:
				var velocity_diff = desired_velocity - rock.linear_velocity
				rock.apply_central_force(velocity_diff * rock.mass * 10.0)
				#rock.global_position += (-rock_detector.global_basis.z * 0.5 * delta)
			if conveyor_rocks.is_empty():
				state = "idle"

		if state == "extract":
			var bodies_on_conveyor = box_detector.get_overlapping_bodies()
			var desired_velocity = box_detector.global_basis.z * 2
			for body: RigidBody3D in bodies_on_conveyor:
				var velocity_diff = desired_velocity - body.linear_velocity
				body.apply_central_force(velocity_diff * body.mass * 10.0)

		rocks_on_conveyor = conveyor_rocks.size()
		# Sum the rock + ore volume currently on the input conveyor (preview for SEND).
		conveyor_rock_volume = 0.0
		conveyor_ore_volume = 0.0
		for r in conveyor_rocks:
			if r.has_method("get_volume"):
				conveyor_rock_volume += r.get_volume()
			if r.has_method("get_ore_volume"):
				conveyor_ore_volume += r.get_ore_volume()
		if rocks_on_conveyor != _last_sent_conveyor or ore_volume != _last_sent_ore \
				or extracted_volume != _last_sent_extracted or conveyor_ore_volume != _last_sent_conv \
				or state != _last_sent_state:
			_last_sent_conveyor = rocks_on_conveyor
			_last_sent_ore = ore_volume
			_last_sent_extracted = extracted_volume
			_last_sent_conv = conveyor_ore_volume
			_last_sent_state = state
			server_prop_update({
				"rocks_on_conveyor": rocks_on_conveyor,
				"rock_volume": rock_volume,
				"ore_volume": ore_volume,
				"extracted_volume": extracted_volume,
				"conveyor_rock_volume": conveyor_rock_volume,
				"conveyor_ore_volume": conveyor_ore_volume,
				"state": state
			})
		#print("on server rock count", rocks.size())
	else:
		# update ui and materials from client state
		var available := ore_volume - extracted_volume
		# Conveyor preview (what SEND will collect): ore purity % + rock/ore volumes.
		var conv_purity := 0.0
		if conveyor_rock_volume > 0.0:
			conv_purity = conveyor_ore_volume / conveyor_rock_volume * 100.0
		rock_depot_ui.get_node("VB/RockCounter/VB/RockCount").text = "%d%%" % int(round(conv_purity))
		rock_depot_ui.get_node("VB/RockCounter/VB/RockCountLabel").text = \
			"ORE PURITY\n%.2f m3 rock  -  %.2f m3 ore" % [conveyor_rock_volume, conveyor_ore_volume]
		# CURRENT STOCK = ore available to be packed into crates.
		rock_depot_ui.get_node("RockTotalLabel/RockTotal").text = "%.2f m3" % available

		if state == "idle":
			rock_depot_ui.get_node("VB/Splashscreen").visible = rocks_on_conveyor == 0
			rock_depot_ui.get_node("VB/RockCounter").visible = rocks_on_conveyor > 0
			# Crate fill progress: ore accumulates toward a full crate; any leftover after
			# an extract keeps filling the next one (extracted_volume grows by exactly one
			# crate per extract, so `available` keeps the remainder).
			var cv := crate_volume()
			var extract_ready: bool = cv > 0.0 and available >= cv
			rock_depot_ui.get_node("VB/Splashscreen/TriggerExtract").visible = extract_ready
			var splash_label: Label = rock_depot_ui.get_node("VB/Splashscreen/Label3")
			if available <= 0.0:
				splash_label.text = "PLACE YOUR ROCK FRAGMENTS\nON THE RIGHT-HAND CONVEYOR."
			elif extract_ready:
				splash_label.text = "CRATE FULL - READY TO EXTRACT"
			else:
				splash_label.text = "CRATE FILLING\n%d%%" % int(clampf(available / cv, 0.0, 1.0) * 100.0)

			danger_light_collect.enabled = false
			danger_light_box.enabled = false
			rock_conveyor.set_instance_shader_parameter("animation_speed", 0.0)
			box_conveyorbelt.set_instance_shader_parameter("animation_speed", 0.0)
		elif state == "collect":
			danger_light_collect.enabled = true
			rock_conveyor.set_instance_shader_parameter("animation_speed", 1.0)
		elif state == "extract":
			danger_light_box.enabled = true
			box_conveyorbelt.set_instance_shader_parameter("animation_speed", -1.0)


func get_rocks_on_conveyor():
	return filter_rocks(rock_detector.get_overlapping_bodies())

func get_rocks_to_collect():
	return filter_rocks(rock_collector.get_overlapping_bodies())

func box_exited(_body: Node3D):
	print("body exited")
	if state == "extract" and box_detector.get_overlapping_bodies().is_empty():
		state = "idle"

func filter_rocks(entities: Array):
	var filtered_rocks = []
	for entity: Node3D in entities:
		if entity.is_in_group("miningrock"):
			filtered_rocks.push_back(entity)
	return filtered_rocks

## Fillable volume of one crate (m3), read once from the crate_container scene.
func crate_volume() -> float:
	if _crate_volume < 0.0:
		var c: Node = CRATE_SCENE.instantiate()
		var cs: CollisionShape3D = c.get_node_or_null("CollisionShape3D")
		if cs != null and cs.shape is BoxShape3D:
			var s: Vector3 = (cs.shape as BoxShape3D).size
			_crate_volume = s.x * s.y * s.z
		else:
			_crate_volume = 1.0
		c.free()
	return _crate_volume

## Accumulate a collected rock's volume into the refining stats, then remove it.
func _collect_rock(rock: Node) -> void:
	if rock.has_method("get_volume"):
		rock_volume += rock.get_volume()
	if rock.has_method("get_ore_volume"):
		ore_volume += rock.get_ore_volume()
	rock.queue_free()

# Server-side state update: forward to the PropSync component, preserving the {"data": ...} envelope
# that the client half (apply_prop_data) expects. PropSync emits it with the depot's uuid/type_name.
func server_prop_update(data):
	var s := _prop_sync()
	if s != null:
		s.server_prop_update({"data": data})

# PropSync applies the replicated transform, then calls this with the full payload so the depot can
# apply its own machine state. Replaces the old client_channel_data_update override.
func apply_prop_data(_data: Dictionary) -> void:
	# sync state from server with client (guard: a generic spawn may omit "data")
	if _data.has("data"):
		var metadata = _data["data"]
		state = metadata.get("state", state)
		rocks_on_conveyor = metadata.get("rocks_on_conveyor", rocks_on_conveyor)
		rock_volume = metadata.get("rock_volume", rock_volume)
		ore_volume = metadata.get("ore_volume", ore_volume)
		extracted_volume = metadata.get("extracted_volume", extracted_volume)
		conveyor_rock_volume = metadata.get("conveyor_rock_volume", conveyor_rock_volume)
		conveyor_ore_volume = metadata.get("conveyor_ore_volume", conveyor_ore_volume)


func handle_extract():
	# Need a full crate's worth of available ore to pack one (the EXTRACT button is
	# gated on this too). Bail out gracefully otherwise.
	var cv := crate_volume()
	if ore_volume - extracted_volume < cv:
		state = "idle"
		return
	extracted_volume += cv
	# Spawn the crate both in Horizon (other clients) and locally on this game server
	# (so it has a physics body that falls onto the belt and replicates). See
	# NetworkOrchestrator.spawn_prop_authoritative.
	var data := {
		"type": "crate_container",
		"uuid": UUID_UTIL.new().as_string(),
		"position": {
			"x": box_spawn_origin.position.x,
			"y": box_spawn_origin.position.y,
			"z": box_spawn_origin.position.z
		},
		"rotation": {"x": 0, "y": 0, "z": 0},
		"content": {"ore_volume": cv},
		"scenename": CRATE_SCENENAME,
		"parent_id": uuid,
	}
	NetworkOrchestrator.spawn_prop_authoritative(data)
	# One-shot delivery: the crate spawns at the belt end, so it never transits
	# BoxDetector. Run the belt briefly for feedback, then return to idle.
	await get_tree().create_timer(2.5).timeout
	if state == "extract":
		state = "idle"


func _on_rock_depot_ui_action_triggered(type: String) -> void:
	if GameOrchestrator.is_server(): return
	# on client trigger the screen state update for the current player if pressed on ui element
	var player: Player = NetworkOrchestrator.network_agent.player_entity
	player.client_send_action_to_server({
		"action": "screen_state",
		"state": type
	})

func update_screen(data: Dictionary):
	var target_state = data["state"]
	# handle state change from client
	if state == "idle" and target_state == "collect":
		state = target_state

	if state == "idle" and target_state == "extract":
		state = target_state
		handle_extract()


## Where a player's camera should look while using this screen: the screen SURFACE, not the depot's
## origin (they are metres apart). Part of the informal "3D screen" contract — PlayerClient calls it
## when present and falls back to the node itself, so a simpler screen needs nothing at all.
func screen_look_target() -> Node3D:
	return get_node_or_null("miningdepot/Gui3D") as Node3D


## 3D-screen contract: a player's proximity monitor gained (or lost) this console. The PLAYER owns
## `screen_interacting` and is the single active monitor of the game (Player.connect_area_detect), so
## all we do here is note who is using the machine.
## This used to be a pair of body_entered / body_exited handlers on our own Area3D, with a half-second
## grace period bolted on to survive the planet's spin. Both are gone: an area-to-area overlap cannot
## desynchronise across a moving frame, so there is no false exit left to absorb (see ScreenZone).
func screen_focus_changed(player: Player, focused: bool) -> void:
	if focused:
		active_player = player
		return
	if is_instance_valid(active_player) and active_player.client_uuid == player.client_uuid:
		active_player = null
