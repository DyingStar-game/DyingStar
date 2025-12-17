extends StaticBody3D

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

var uuid: String = ""

@export var placeholder = false

var type_name = "mining_depot"

signal hs_server_prop_update

@warning_ignore("unused_signal")
signal client_action_requested(datas: Dictionary)

var spawn_position

@onready var rock_depot_ui: Panel = %RockDepotUI
@onready var danger_light_collect: Node3D = $DangerLightCollect
@onready var conveyorbelt_001: MeshInstance3D = $miningdepot/conveyorbelt_001
@onready var rock_detector: Area3D = $RockDetector
@onready var rock_collector: Area3D = $RockCollector

var state := "idle"
var rocks_on_conveyor := 0
var rocks_collected := 0

var active_player: Player

func _ready() -> void:
	if placeholder:
		if GameOrchestrator.is_server():
			await get_tree().create_timer(1).timeout
			var parent = get_parent()

			var message = {
				"namespace": "props",
				"event": "create_object",
				"amessagenb": 1,
				"data": [
					{
						"type": type_name,
						"uuid": UUID_UTIL.new().as_string(),
						"position": {
							"x": position[0],
							"y": position[1],
							"z": position[2]
						},
						"rotation": {
							"x": rotation[0],
							"y": rotation[1],
							"z": rotation[2]
						},
						"data": {
							"state": "idle",
							"rocks_on_conveyor": 0,
							"rocks_collected": 0,
							"active_player": null
						},
						"scenename": "scenes/structures/mining_depot.tscn",
						"parent_id": parent.uuid,
					}
				]
			}
			ServerNetwork.send_message(message, "devmodecreate_object")

		queue_free()

func _process(_delta: float) -> void:
	if GameOrchestrator.is_server():
		var conveyor_rocks = get_rocks_on_conveyor()
		var collect_rocks = get_rocks_to_collect()
	
		for rock in collect_rocks:
			rocks_collected += 1
			rock.queue_free()

		if state == "collect":
			var desired_velocity = -rock_detector.global_basis.z * 2
			# move rocks on conveyor
			for rock: RigidBody3D in conveyor_rocks:
				var velocity_diff = desired_velocity - rock.linear_velocity
				rock.apply_central_force(velocity_diff * rock.mass * 10.0)
				#rock.global_position += (-rock_detector.global_basis.z * 0.5 * delta)
			if conveyor_rocks.is_empty():
				state = "idle"

		rocks_on_conveyor = conveyor_rocks.size()
		server_prop_update({
			"rocks_on_conveyor": rocks_on_conveyor,
			"rocks_collected": rocks_collected,
			"state": state
		})
		#print("on server rock count", rocks.size())
	else:
		# update ui and materials from client state
		rock_depot_ui.get_node("VB/RockCounter/VB/RockCount").text = str(int(rocks_on_conveyor))
		rock_depot_ui.get_node("RockTotalLabel/RockTotal").text = str(int(rocks_collected))

		if state == "idle":
			rock_depot_ui.get_node("VB/Splashscreen").visible = rocks_on_conveyor == 0
			rock_depot_ui.get_node("VB/RockCounter").visible = rocks_on_conveyor > 0

			danger_light_collect.enabled = false
			conveyorbelt_001.set_instance_shader_parameter("animation_speed", 0.0)
		elif state == "collect":
			danger_light_collect.enabled = true
			conveyorbelt_001.set_instance_shader_parameter("animation_speed", 1.0)

func get_rocks_on_conveyor():
	return filter_rocks(rock_detector.get_overlapping_bodies())

func get_rocks_to_collect():
	return filter_rocks(rock_collector.get_overlapping_bodies())

func filter_rocks(entities: Array):
	var filtered_rocks = []
	for entity: Node3D in entities:
		if entity.is_in_group("rock_mining"):
			filtered_rocks.push_back(entity)
	return filtered_rocks

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
		type_name
	)

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

	var metadata = _data["data"]
	# sync state from server with client
	state = metadata["state"]
	rocks_on_conveyor = metadata["rocks_on_conveyor"]
	rocks_collected = metadata["rocks_collected"]


func handle_extract():
	# create box and fill with rocks
	
	rocks_collected = 0
	pass

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

func _on_player_leave(body: Node3D) -> void:
	if body is Player and body.client_uuid == active_player.client_uuid:
		active_player = null
		body.screen_interacting = null
