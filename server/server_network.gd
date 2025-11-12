extends Node

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")

# Websocket port we will listen to (Horizon server or godot client in devmode).
var port = 8980

# Our TCP Server instance.
var tcp_server = TCPServer.new()

# Our connected peers list.
var peer := WebSocketPeer.new()


var devmode: bool = false
var devscene: String = ""

var sceneuuid: String = UUID_UTIL.v4()

func _enter_tree() -> void:
	for argument in OS.get_cmdline_args():
		if argument.contains("devmode="):
			var key_value = argument.split("=")
			devscene = key_value[1]
			devmode = true
			port = 7040

func _ready() -> void:
	set_process(false)

func start_websocket_server():
	var err = tcp_server.listen(port)
	if err == OK:
		print("Server socket started.")
		set_process(true)
	else:
		push_error("Unable to start server socket.")
	return true

func _process(_delta: float) -> void:
	while ServerNetwork.tcp_server.is_connection_available():
		print("Peer connected (Horizon server).")
		peer.accept_stream(ServerNetwork.tcp_server.take_connection())

	peer.poll()

	var peer_state = peer.get_ready_state()
	if peer_state == WebSocketPeer.STATE_OPEN:
		while peer.get_available_packet_count():
			var packet = peer.get_packet()
			if peer.was_string_packet():
				var packet_text = packet.get_string_from_utf8()
				print("SERVER - Received packet: %s" % [packet_text])
				var message = JSON.parse_string(packet_text)
				if message != null:
					dispatch_horizon_message(message)
					if devmode:
						_devmode_horizon_mapping(message)
			else:
				print("< Got binary data from peer: %d ... echoing" % [packet.size()])
				peer.send(packet)

func dispatch_horizon_message(message: Dictionary):
	# SERVER - Received packet:
	# {
	#     "data": {
	#         "object_data": {
	#             "name": "tarsis II",
	#             "position": {
	#                 "x": 0,
	#                 "y": 10000000,
	#                 "z": 10000000
	#             },
	#             "rotation": {
	#                 "x": 0,
	#                 "y": 0,
	#                 "z": 0
	#             },
	#             "scenename": "tarsis_II"
	#         },
	#         "object_type": "planets",
	#         "object_uuid": "6f3b006e-a6e3-493b-ba3b-57a180a09cc5"
	#     },
	#     "event": "add_prop",
	#     "namespace": "server"
	# }

	if message['namespace'] == "server":
		match message['event']:
			"add_prop":
				match message["data"]["object_type"]:
					"planet":
						# spawn planet
						NetworkOrchestrator.network_agent.create_planet(message)
					"player":
						NetworkOrchestrator.network_agent.create_player(message)
					_:
						NetworkOrchestrator.network_agent.create_generic_object(message)

	elif message['namespace'] == "player":
		match message['event']:
			"spawn":
				NetworkOrchestrator.network_agent.instantiate_player(message)
			"move":
				NetworkOrchestrator.network_agent.player_move(message)
			"action":
				NetworkOrchestrator.network_agent.player_action(message)

func send_message(message: Dictionary, message_type: String):
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _devmode_mapping_send(message, message_type):
			peer.send_text(JSON.stringify(message))





################################################################
# devmode - mapping of messages to permit have
# godot client speak directly with godot server without Horizon
#
# WARNING: some parts managed in Horizon can't works in devmode
#
# CAUTION: NOT TOUCH UNDER THIS LINE IF YOU DON'T KNOW
#################################################################

### Init server in devmode
func _init_server_network_devmode():
	if devmode:
		print("DevMode activated - scene: " + devscene)

		NetworkOrchestrator.network_agent.create_generic_object({
			"namespace": "server",
			"event": "add_prop",
			"data": {
				"object_uuid": sceneuuid,
				"object_type": "genericprop",
				"object_data": {
					"position": {"x":0.0, "y": 0.0, "z":0.0},
					"rotation": {"x":0.0, "y": 0.0, "z":0.0},
					"scenename": "levels/devmode/" + devscene + "/" + devscene + ".tscn",
					"parent_id": "",
				}
			}
		})

func _devmode_mapping_send(message: Dictionary, message_type: String):
	if devmode:
		match message_type:
			"player_position":
				_devmode_mapping_players_position(message)
				return true
			"prop_position":
				_devmode_mapping_props_position(message)
				return true
	return false

func _devmode_mapping_players_position(message: Dictionary):
	# Convert player position
	#
	# from:
	# {
	#   "namespace": "player",
	#   "event": "position",
	#   "amessagenb": 1,
	#   "data": [
	#       {
	#           "player_id": "029eaef4-8e7d-41a6-abf4-d6778fbf38e0",
	#           "pos": {"x":0.0, "y":0.0, "z":0.0},
	#           "rot": {"x":0.0, "y":0.0, "z":0.0}
	#       },
	#       ...
	#   ]
	# }
	#
	# to:
	# {
	#   "channel": 0,
	#   "data": {
	#     "client_timestamp": "2025-11-08T06:32:35.735561403Z",
	#     "movement_state": 1,
	#     "new_position": {
	#       "x": -2203849.8893,
	#       "y": 4.0825,
	#       "z": 0.7945
	#     },
	#     "player_id": "8fb82d2b-1e6d-48f5-8387-90979f97e274",
	#     "velocity": {
	#       "x": 0,
	#       "y": 0,
	#       "z": 0
	#     }
	#   },
	#   "event_type": "move",
	#   "object_id": "82203c32-7acc-47cb-9abe-34fc4ac1318e",
	#   "object_type": "GorcPlayer",
	#   "player_id": "82203c32-7acc-47cb-9abe-34fc4ac1318e",
	#   "timestamp": 1762583555
	# }
	#

	for data in message["data"]:
		peer.send_text(
			JSON.stringify({
				"channel": 0,
				"event_type": "move",
				"object_id": data["player_id"],
				"object_type": "GorcPlayer",
				"player_id": data["player_id"],
				"timestamp": int(Time.get_unix_time_from_system()),
				"data": {
					"client_timestamp": "2025-11-08T06:32:35.735561403Z",
					"movement_state": 1,
					"new_position": data["pos"],
					"player_id": data["player_id"],
					"velocity": {
						"x": 0,
						"y": 0,
						"z": 0
					},
				}
			})
		)

func _devmode_mapping_props_position(message: Dictionary):
	# Convert player position
	#
	# from:
	# {
	#   "namespace": "props",
	#   "event": "position",
	#   "amessagenb": 1,
	#   "data": [
	#       {
	#           "uuid": "029eaef4-8e7d-41a6-abf4-d6778fbf38e0",
	#           "pos": {"x":0.0, "y":0.0, "z":0.0},
	#           "rot": {"x":0.0, "y":0.0, "z":0.0},
	#           "type": "box"
	#       },
	#       ...
	#   ]
	# }
	#
	# to:
	# {
	#   "channel": 0,
	#   "data": {
	#     "object_data": {
	#       "pos": {
	#         "x": -2203849.86215246,
	#         "y": 5.11689467541873,
	#         "z": 2.13528040036042
	#       },
	#       "rot": {
	#         "x": 1.01564578285282,
	#         "y": -0.0836469790948896,
	#         "z": -0.0504217741125035
	#       },
	#       "type": "box",
	#       "uuid": "d89afbf7-01ef-402c-8a1e-5b28605164ed"
	#     },
	#     "object_id": "d89afbf7-01ef-402c-8a1e-5b28605164ed",
	#     "object_type": "box"
	#   },
	#   "event_type": "gorc_update",
	#   "object_id": "d89afbf7-01ef-402c-8a1e-5b28605164ed",
	#   "object_type": "box",
	#   "player_id": "d89afbf7-01ef-402c-8a1e-5b28605164ed",
	#   "timestamp": 1762583555
	# }
	#
	for data in message["data"]:
		peer.send_text(
			JSON.stringify({
				"channel": 0,
				"event_type": "gorc_update",
				"object_id": data["uuid"],
				"object_type": data["type"],
				"player_id": data["uuid"],
				"timestamp": int(Time.get_unix_time_from_system()),
				"data": {
					"object_data": {
						"pos": data["pos"],
						"rot": data["rot"],
						"type": data["type"],
						"uuid": data["uuid"],
					},
					"object_id": data["uuid"],
					"object_type": data["type"],
				}
			})
		)

### Messages mapping from godot client to godot server in devmode (Horizon in non-devmode)
func _devmode_horizon_mapping(message: Dictionary):
	match message['namespace']:
		"player":
			match message['event']:
				"init":
					# {
					# 	"namespace": "player",
					# 	"event": "init",
					# 	"data": {
					# 		"login": "tatayoyo",
					# 		"password": "pass"
					# 	}
					# }
					peer.send_text(
						JSON.stringify({
							"player_id":"82203c32-7acc-47cb-9abe-34fc4ac1318e",
							"type":"init_ack"
						})
					)

					# Create the test level on client side
					peer.send_text(
						JSON.stringify(
							{
								"channel": 0,
								"data": {
									"object_data": {
										"parent_id": "",
										"position": {
											"x": 0,
											"y": 0,
											"z": 0
										},
										"rotation": {
											"x": 0,
											"y": 0,
											"z": 0
										},
										"scenename": "levels/devmode/" + devscene + "/" + devscene + ".tscn"
									},
									"object_id": sceneuuid,
									"object_type": "testlevel",
									"position": {
										"x": 0,
										"y": 0,
										"z": 0
									}
								},
								"event_type": "gorc_create",
								"object_id": sceneuuid,
								"object_type": "testlevel",
								"player_id": sceneuuid,
								"timestamp": int(Time.get_unix_time_from_system())
							}
						)
					)

					# create player on server side
					NetworkOrchestrator.network_agent.create_player({
						"namespace": "server",
						"event": "add_prop",
						"data": {
							"object_uuid": "82203c32-7acc-47cb-9abe-34fc4ac1318e",
							"object_type": "player",
							"object_data": {
								"connection_id": "82203c32-7acc-47cb-9abe-34fc4ac1318e",
								"parent_id": sceneuuid,
								"position": {"x":0.0, "y": 1.0, "z":0.0},
								"rotation": {"x":0.0, "y": 0.0, "z":0.0},
								"name": "DevModePlayer"
							}
						}
					})

					# send zone enter for player on client side
					peer.send_text(
						JSON.stringify({
							"channel": 0,
							"object_id": "82203c32-7acc-47cb-9abe-34fc4ac1318e",
							"object_type": "GorcPlayer",
							"player_id": "82203c32-7acc-47cb-9abe-34fc4ac1318e",
							"timestamp": int(Time.get_unix_time_from_system()),
							"type": "gorc_zone_enter",
							"zone_data": {
								"health": 100,
								"parent_id": sceneuuid,
								"position": {
									"x": 0,
									"y": 1,
									"z": 0
								},
								"velocity": {
									"x": 0,
									"y": 0,
									"z": 0
								}
							}
						})
					)
		"movement":
			match message['event']:
				"update_velocity":
					# from client:
					# {
					# 	"namespace": "movement",
					# 	"event": "update_velocity",
					# 	"data": {
					# 		"pos": {
					# 			"x": move_direction[0],
					# 			"y": move_direction[1]
					# 		},
					# 		"rot": {
					# 			"x": move_rotation[0],
					# 			"y": move_rotation[1],
					# 			"z": move_rotation[2]
					# 		},
					# 		"uuid": player_entity.client_uuid
					# 	},
					# }
					NetworkOrchestrator.network_agent.player_move({
						"namespace": "player",
						"event": "move",
						"player_id": message["data"]["uuid"],
						"data": message["data"]
					})

		"props":
			match message['event']:
				"spawn_request":
					# from client:
					# {
					# 	"namespace": "actions",
					# 	"event": "spawn_request",
					# 	"data": {
					#     "action": "spawn",
					#     "entity": "box",
					#     "position": {
					# 	    "x": 0.0,
					# 	    "y": 0.0,
					# 	    "z": 0.0
					#     },
					#     "scenename": "scenes/props/testbox/spawn_50cmbox.tscn",
					#     "parent_id": "9b3ec158-7789-46fb-9890-ad84c691c1a5",
					# 	},
					# }
					#
					# to client (from horizon):
					# {
					# 	"channel": 0,
					# 	"data": {
					# 		"object_data": {
					# 			"parent_id": "3388a817-f3ef-421d-b10f-4325e105628e",
					# 			"position": {
					# 				"x": -2203850,
					# 				"y": 2,
					# 				"z": 16.4841
					# 			},
					# 			"rotation": {
					# 				"x": 0,
					# 				"y": 0,
					# 				"z": 0
					# 			},
					# 			"scenename": "scenes/props/testbox/box_50cm.tscn"
					# 		},
					# 		"object_id": "4cf7f72d-ba93-4968-b7b1-9ffec31d5845",
					# 		"object_type": "box50cm",
					# 		"position": {
					# 			"x": -2203850,
					# 			"y": 2,
					# 			"z": 16.4841
					# 		}
					# 	},
					# 	"event_type": "gorc_create",
					# 	"object_id": "4cf7f72d-ba93-4968-b7b1-9ffec31d5845",
					# 	"object_type": "box50cm",
					# 	"player_id": "4cf7f72d-ba93-4968-b7b1-9ffec31d5845",
					# 	"timestamp": 1762519740
					# }

					# 1/ create prop on server side
					var uuid = UUID_UTIL.v4()

					message["data"]["rotation"] = {
						"x": 0.0,
						"y": 0.0,
						"z": 0.0
					}
					message["data"]["parent_id"] = sceneuuid
					NetworkOrchestrator.network_agent.create_generic_object({
						"data": {
							"object_data": message["data"],
							"object_type": "planets",
							"object_uuid": uuid
						},
						"event": "add_prop",
						"namespace": message["data"]["entity"]
					})

					# 2/ send message to client (gorc_create)
					peer.send_text(
						JSON.stringify({
							"channel": 0,
							"data": {
								"object_data": {
									"parent_id": sceneuuid,
									"position": message["data"]["position"],
									"rotation": message["data"]["rotation"],
									"scenename": message["data"]["scenename"]
								},
								"object_id": uuid,
								"object_type": message["data"]["entity"],
								"position": message["data"]["position"],
							},
							"event_type": "gorc_create",
							"object_id": uuid,
							"object_type": message["data"]["entity"],
							"player_id": uuid,
							"timestamp": int(Time.get_unix_time_from_system())
						})
					)
