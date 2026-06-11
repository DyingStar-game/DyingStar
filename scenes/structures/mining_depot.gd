extends StaticBody3D

signal hs_server_prop_update

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
const CRATE_SCENE = preload("res://scenes/props/cargo/palette_container.tscn")

@export var placeholder = false
## Optional explicit network id for a designer-placed depot. Leave EMPTY and it is derived
## automatically from the depot's fixed position (stable across restarts, no setup needed).
## Set a unique string only if you want a readable id or to keep identity when moving it.
@export var stable_id: String = ""

var uuid: String = ""
var has_parent: bool = false
var type_name = "mining_depot"
var spawn_position
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

# Throttle: only replicate the depot state when it actually changes.
var _last_sent_conveyor := -1
var _last_sent_state := ""
var _last_sent_ore := -1.0
var _last_sent_extracted := -1.0
var _last_sent_conv := -1.0
# Cached fillable volume of one crate (palette_container), read from its scene.
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

			# Spawn the real networked depot to replace this editor placeholder. Use
			# spawn_prop_authoritative so it is registered in Horizon AND created locally on
			# this game server (the server copy is what holds the collision and the detectors
			# / collect / SEND logic). Sending only to Horizon would leave the server without
			# a depot node, since Horizon does not echo create_object back.
			# Deterministic, VALID-format uuid so this depot is always the SAME object across
			# restarts (the database upserts by uuid -> no duplicate pile-up, and no delete is
			# needed). Seed from the explicit stable_id, else from the fixed placement position
			# so no manual setup is required.
			var uuid_seed: String = stable_id if stable_id != "" \
				else "%.3f,%.3f,%.3f" % [position.x, position.y, position.z]
			var depot_uuid: String = _stable_uuid(uuid_seed)
			# Designer-placed depot = world infrastructure: protect it from the admin cleanup
			# tool (only player-spawned depots should be deletable).
			NetworkOrchestrator.protected_prop_uuids[depot_uuid] = true
			NetworkOrchestrator.spawn_prop_authoritative({
				"type": type_name,
				"uuid": depot_uuid,
				"position": {
					"x": position.x,
					"y": position.y,
					"z": position.z
				},
				"rotation": {
					"x": rotation.x,
					"y": rotation.y,
					"z": rotation.z
				},
				"data": {
					"state": "idle",
					"rocks_on_conveyor": 0,
					"rock_volume": 0.0,
					"ore_volume": 0.0,
					"extracted_volume": 0.0,
					"active_player": null
				},
				"scenename": "scenes/structures/mining_depot.tscn",
				"parent_id": parent.uuid,
			})

		queue_free()

	if GameOrchestrator.is_server():
		box_detector.body_exited.connect(box_exited)
		rock_detector.body_exited.connect(_on_rock_exited)

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

## Fillable volume of one crate (m3), read once from the palette_container scene.
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

func server_prop_update(data):
	server_send_properties_to_client({
		"data": data
	})


# Send the properties of the entity from godot server to horizon / client
func server_send_properties_to_client(data: Dictionary):
	emit_signal(
		"hs_server_prop_update",
		uuid,
		data,
		type_name,
		has_parent
	)

# Reparent on the client when the prop is spawned under a parent (e.g. the planet).
func client_parent_change(parent: Node) -> void:
	reparent(parent)
	has_parent = true

# receive the properties sent by the server part (Horizon / godot server)
# this function is used to update the properties of the entity on client side
func client_channel_data_update(_data: Dictionary) -> void:
	# sync position + rotation on spawn
	if _data.has("position"):
		position = Vector3(
			_data["position"]["x"],
			_data["position"]["y"],
			_data["position"]["z"]
		)
	if _data.has("rotation"):
		rotation = Vector3(
			_data["rotation"]["x"],
			_data["rotation"]["y"],
			_data["rotation"]["z"]
		)

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
		"type": "palette_container",
		"uuid": UUID_UTIL.new().as_string(),
		"position": {
			"x": box_spawn_origin.position.x,
			"y": box_spawn_origin.position.y,
			"z": box_spawn_origin.position.z
		},
		"rotation": {"x": 0, "y": 0, "z": 0},
		"content": {"ore_volume": cv},
		"scenename": "scenes/props/cargo/palette_container.tscn",
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


func _on_player_interact(body: Node3D) -> void:
	if body is Player:
		active_player = body
		body.screen_interacting = self
		# Tell the player where the screen is so its camera can turn to face it.
		var screen := get_node_or_null("miningdepot/Gui3D")
		body.screen_position = screen.global_position if screen else global_position

func _on_player_leave(body: Node3D) -> void:
	if body is Player and body.client_uuid == active_player.client_uuid:
		active_player = null
		body.screen_interacting = null
