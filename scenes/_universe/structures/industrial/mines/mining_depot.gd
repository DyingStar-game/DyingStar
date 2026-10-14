extends NetStaticBody  # the uuid facade (see NetStaticBody)

## Networked mining depot. Networking (uuid, replication, reparent, delete) lives in the PropSync child
## node (type_name "mining_depot", non-carriable); machine state is applied via apply_prop_data(), and
## server-side state updates go out via server_prop_update() which forwards to the PropSync component.

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## The crate the depot packs its ore into. It replicates as the "crate_container" TYPE (that def is
## the one whose channels carry `content`, the ore volume) — only the scene differs. Its physical size
## is what crate_volume() reads to decide how much ore fills one crate.
const CRATE_SCENE = preload("res://scenes/_universe/props/containers/hauling_box.tscn")
const CRATE_SCENENAME = "scenes/_universe/props/containers/hauling_box.tscn"
## Designer-placed depot: tick it on the instance dropped in a world scene. On the server it spawns the REAL
## networked depot at the same spot (deterministic uuid) and frees itself.
@export var placeholder = false
## Optional explicit network id for a designer-placed depot. Leave EMPTY and it is derived
## automatically from the depot's fixed position (stable across restarts, no setup needed).
## Set a unique string only if you want a readable id or to keep identity when moving it.
@export var stable_id: String = ""

var type_name = "mining_depot"  # kept for the placeholder self-spawn; PropSync carries the networked copy
var state := "idle"

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

## Ore still in the depot, per mineral id ("gold" -> m3). The totals above are what the screen shows,
## but a crate has to be ONE mineral: a crate of blended ore is not a good anybody can be paid in,
## and service-inventory trades by goodType. So the split lives here, on the server only, and a
## crate is packed from the first mineral (alphabetical, so two servers agree) that has a full one
## left. A depot fed gold and iron therefore yields gold crates until gold runs dry, then iron.
var _stock: Dictionary = {}

# Throttle: only replicate the depot state when it actually changes.
var _last_sent_conveyor := -1
var _last_sent_state := ""
var _last_sent_ore := -1.0
var _last_sent_extracted := -1.0
var _last_sent_conv := -1.0
var _last_sent_packable := false
## Whether a whole crate of ONE mineral is ready, which is what the EXTRACT button is gated on and
## what handle_extract() actually tests. The screen's `available` total can clear the crate volume
## while no single mineral can — blended ore — so the gate cannot be computed from the total alone.
var packable := false
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

		# Whether a crate is ready is a SERVER fact: it is per mineral, and the client only ever sees
		# the blended total. Computed before the throttle so a single frame of change is not missed.
		packable = mineral_to_pack(_stock, MissionHeartbeat.units_of_volume(crate_volume())) != ""

		if state == "collect" and conveyor_rocks.is_empty():
			state = "idle"

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
				or state != _last_sent_state or packable != _last_sent_packable:
			_last_sent_conveyor = rocks_on_conveyor
			_last_sent_ore = ore_volume
			_last_sent_extracted = extracted_volume
			_last_sent_conv = conveyor_ore_volume
			_last_sent_state = state
			_last_sent_packable = packable
			server_prop_update({
				"rocks_on_conveyor": rocks_on_conveyor,
				"rock_volume": rock_volume,
				"ore_volume": ore_volume,
				"extracted_volume": extracted_volume,
				"conveyor_rock_volume": conveyor_rock_volume,
				"conveyor_ore_volume": conveyor_ore_volume,
				"state": state,
				"packable": packable
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
			tr("%%HUD_ORE_PURITY") % [conveyor_rock_volume, conveyor_ore_volume]
		# CURRENT STOCK = ore available to be packed into crates.
		rock_depot_ui.get_node("RockTotalLabel/RockTotal").text = "%.2f m3" % available

		if state == "idle":
			rock_depot_ui.get_node("VB/Splashscreen").visible = rocks_on_conveyor == 0
			rock_depot_ui.get_node("VB/RockCounter").visible = rocks_on_conveyor > 0
			# Crate fill progress: ore accumulates toward a full crate; any leftover after
			# an extract keeps filling the next one (extracted_volume grows by exactly one
			# crate per extract, so `available` keeps the remainder).
			var cv := crate_volume()
			# The server's `packable`, not the local total: the total clears the crate volume while
			# the ore is split gold/iron, and a blended crate is not a crate the server will pack.
			var extract_ready: bool = cv > 0.0 and packable
			rock_depot_ui.get_node("VB/Splashscreen/TriggerExtract").visible = extract_ready
			var splash_label: Label = rock_depot_ui.get_node("VB/Splashscreen/Label3")
			if available <= 0.0:
				splash_label.text = "%%HUD_DEPOT_PLACE"
			elif extract_ready:
				splash_label.text = "%%HUD_DEPOT_FULL"
			else:
				splash_label.text = tr("%%HUD_DEPOT_FILLING") % int(clampf(available / cv, 0.0, 1.0) * 100.0)

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


## Server: drive the belts. In _physics_process, never _process: a force lasts ONE physics step (Jolt
## clears it after each), so pushed from _process it only acts on the first of the steps a slow frame
## catches up — the other steps are pure friction. With 2 steps per frame (any server frame over
## 16.7 ms) a rock crept 0.29 m in 4 s instead of reaching the collector: "the belt sometimes works".
func _physics_process(_delta: float) -> void:
	if not GameOrchestrator.is_server():
		return
	if state == "collect":
		_push_belt(get_rocks_on_conveyor(), -rock_detector.global_basis.z * 2)
	elif state == "extract":
		_push_belt(box_detector.get_overlapping_bodies(), box_detector.global_basis.z * 2)

## Pull every body on a belt towards [param desired_velocity] (m/s, world space).
func _push_belt(bodies: Array, desired_velocity: Vector3) -> void:
	for body in bodies:
		if body is RigidBody3D:
			var rb: RigidBody3D = body
			rb.apply_central_force((desired_velocity - rb.linear_velocity) * rb.mass * 10.0)

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
## The ore half is ALSO banked per mineral (see [member _stock]): a crate is one mineral, so the
## total alone cannot say which one to pack.
func _collect_rock(rock: Node) -> void:
	if rock.has_method("get_volume"):
		rock_volume += rock.get_volume()
	var ore: float = rock.get_ore_volume() if rock.has_method("get_ore_volume") else 0.0
	if ore > 0.0:
		ore_volume += ore
		var mineral_id := mineral_id_of(rock)
		if mineral_id != "":
			_stock[mineral_id] = float(_stock.get(mineral_id, 0.0)) + ore
	rock.queue_free()


## The mineral this rock actually carries ("gold"), or "" for barren rock and for anything the depot
## cannot name. An inert mineral's `get_ore_volume()` is already 0, so this mostly guards a rock
## node that never had its mineral applied.
static func mineral_id_of(rock: Node) -> String:
	var mineral: Variant = rock.get("mineral")
	if mineral == null or not (mineral is Resource):
		return ""
	var id: Variant = (mineral as Resource).get("id")
	return "" if id == null else str(id)


## The first mineral (alphabetical, so it does not depend on Dictionary order) holding at least
## [param units_needed] of ore, or "" when none does. Static and pure so a test can hand it two
## dicts — the depot's own `_stock` is a Dictionary like any other, and building the scene to ask
## would drag every @onready node in with it.
static func mineral_to_pack(stock: Dictionary, units_needed: int) -> String:
	var need_m3: float = units_needed / MissionHeartbeat.LITRES_PER_M3
	var keys := stock.keys()
	keys.sort()
	for key: Variant in keys:
		if float(stock[key]) >= need_m3:
			return str(key)
	return ""


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
		packable = bool(metadata.get("packable", packable))


func handle_extract():
	# Who is extracting, captured BEFORE the belt await below: active_player is whoever stands at
	# the screen in two and a half seconds' time, which is not the player being credited.
	var extractor: String = active_player.client_uuid if active_player != null else ""
	# One crate is ONE mineral, so the totals cannot say what to pack — the per-mineral stock can.
	# A crate is ≈0.0657 m3, i.e. ZERO in whole metres, hence the litre unit service-inventory trades.
	var units := MissionHeartbeat.units_of_volume(crate_volume())
	var mineral_id := mineral_to_pack(_stock, units)
	if mineral_id == "":
		state = "idle"
		return
	# Spend exactly what will be credited, in whole litres, rather than the float volume: the two
	# differ by under half a litre and the difference would otherwise leak out of the depot's pool
	# on every single extract.
	var packed_m3: float = units / MissionHeartbeat.LITRES_PER_M3
	_stock[mineral_id] = float(_stock[mineral_id]) - packed_m3
	extracted_volume += packed_m3
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
		"content": {"ore_volume": packed_m3, "mineral": mineral_id, "units": units},
		"scenename": CRATE_SCENENAME,
		"parent_id": uuid,
	}
	NetworkOrchestrator.spawn_prop_authoritative(data)
	# The crate is the world object; the inventory is where the GOODS live. Crediting here, on the
	# server, under the player's service identity is what makes the ore a deliver_material
	# objective — a client route would be a minting bug (see MissionHeartbeat.credit_mined).
	_credit_extracted(extractor, mineral_id, units)
	# One-shot delivery: the crate spawns at the belt end, so it never transits
	# BoxDetector. Run the belt briefly for feedback, then return to idle.
	await get_tree().create_timer(2.5).timeout
	if state == "extract":
		state = "idle"


## Hand the packed crate to service-inventory as goods the player now carries. Detached on purpose:
## the crate is already in the world, and a service that is down must not also cost the player their
## belt run — the warning on the failure already says the goods are not accounted for.
func _credit_extracted(player_id: String, mineral_id: String, units: int) -> void:
	var good_type := MissionHeartbeat.good_type_for_mineral(mineral_id)
	if player_id == "" or good_type == "":
		return
	MissionHeartbeat.credit_mined(player_id, good_type, units)
	print("[mining] packed %d x %s for %s" % [units, good_type, player_id])


func _on_rock_depot_ui_action_triggered(type: String) -> void:
	if GameOrchestrator.is_server(): return
	# on client trigger the screen state update for the current player if pressed on ui element
	ScreenTarget.send(self, {"state": type})

func update_screen(data: Dictionary):
	var target_state = data["state"]
	# handle state change from client
	if state == "idle" and target_state == "collect":
		state = target_state

	if state == "idle" and target_state == "extract":
		state = target_state
		handle_extract()


## SERVER, 3D-screen contract (ScreenTarget): the player whose action is about to be handled — who
## is using the machine. It was noted from a proximity zone in front of the console, gone since the
## crosshair points at screens (2026-10-13).
func set_screen_actor(player: Player) -> void:
	active_player = player
