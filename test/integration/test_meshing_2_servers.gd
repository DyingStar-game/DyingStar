extends GutTest

var Server1
var Server2
var Player1 = {
	"id": 6509457,
	"uuid": "32726b4c-119e-4f69-87b1-2495bcabacd9",
	"name": "player 01"
}
var Player2 = {
	"id": 94523332,
	"uuid": "23e5ceb6-457b-49d1-95a8-5577c2792098",
	"name": "player 02"
}
var Player3 = {
	"id": 668345,
	"uuid": "e3c2ce17-07fc-4b68-9edd-02b49c001e7e",
	"name": "player 03"
}

func before_each():
	pass

func after_each():
	pass

func before_all():
	Globals.isGUTRunning = true
	var servermeshingscene = preload("res://test/servermeshing/servermeshing.tscn")
	get_tree().change_scene_to_packed(servermeshingscene)
	await wait_seconds(1)

	Server1 = get_tree().get_current_scene().get_node("Server1")
	Server2 = get_tree().get_current_scene().get_node("Server2")

	# Server 1 config
	Server1.isDedicatedServer = true
	Server1.ServerMaxPlayersAllowed = 2
	Server1.ServerIP = "192.168.0.10"
	Server1.ServerPort = 7050
	Server1.ServerName = "gameserverDev0101"
	Server1.ServerSDOUrl = "mqtt.dev"

	# Server 2 config
	Server2.isDedicatedServer = true
	Server2.ServerMaxPlayersAllowed = 2
	Server2.ServerIP = "192.168.0.10"
	Server2.ServerPort = 7051
	Server2.ServerName = "gameserverDev0102"
	Server2.ServerSDOUrl = "mqtt.dev"

func after_all():
	pass

func test_test():
	assert_true(true)

func test_start_server1():
	Server1._players_spawn_node = Server1.get_node("Players")

	var mqttGUT = preload("res://test/servermeshing/sdoInterface.tscn")
	Server1.MQTTClientSDO = mqttGUT.instantiate()
	# Server1.connect_mqtt_sdo()
	Server1._sdo_register()
	# check register
	assert_eq(Server1.MQTTClientSDO.messages["sdo/register"].size(), 1, "Server 1 must send registered message")
	assert_eq(
		Server1.MQTTClientSDO.messages["sdo/register"][0],
		JSON.stringify({"name": "gameserverDev0101", "ip": "192.168.0.10", "port": 7050}),
		"Message of register not right"
	)

func test_server1_receive_serverslist():
	Server1._on_mqtt_sdo_received_message(
		"sdo/serverslist",
		JSON.stringify([{
			"id": 1,
			"name": "gameserverDev0101",
			"ip": "192.168.0.10",
			"port": 7050,
			"x_start": -10000000,
			"x_end": 10000000,
			"y_start": -10000000,
			"y_end": 10000000,
			"z_start": -10000000,
			"z_end": 10000000,
			"to_merge_server_id": null
		}])
	)
	assert_eq(
		Server1.ServerZone,
		{
			"x_start": -10000000.0,
			"x_end": 10000000.0,
			"y_start": -10000000.0,
			"y_end": 10000000.0,
			"z_start": -10000000.0,
			"z_end": 10000000.0
		},
		"server zone not right"
	)
	assert_eq(Server1.ServerSDOId, 1, "ServerSDOId ,ust be set to 1")
	assert_true(Server1.isSDOActive, "isSDOActive must be true")
	assert_eq(
		Server1.ServerServersList,
		{
			1: {
				"id": 1,
				"name": "gameserverDev0101",
				"ip": "192.168.0.10",
				"port": 7050,
				"x_start": -10000000.0,
				"x_end": 10000000.0,
				"y_start": -10000000.0,
				"y_end": 10000000.0,
				"z_start": -10000000.0,
				"z_end": 10000000.0,
				"to_merge_server_id": null
			}
		}
	)
	assert_eq(Server1.MQTTClientSDO.subscribed, {"sdo/playerslist": true, "sdo/serverschanges": true})


func test_server1_receive_playerslist():
	Server1._on_mqtt_sdo_received_message(
		"sdo/playerslist",
		JSON.stringify([])
	)
	assert_eq(Server1.MQTTClientSDO.subscribed, {"sdo/serverschanges": true, "sdo/playerschanges": true})


func test_server1_player1_connect():
	Server1._on_player_connected(Player1.id)
	Server1.set_player_uuid(Player1.uuid, Player1.name, Player1.id)
	assert_eq(
		Server1.PlayersListTempById.keys(),
		[Player1.id]
	)
	assert_eq(
		Server1.ServerMyPlayersList.keys(),
		[Player1.uuid],
		"ServerMyPlayersList must have player"
	)
	assert_eq(Server1.ServersAllPlayersList.size(), 0, "ServersAllPlayersList must be empty")
	assert_eq(Server1.ServerMyPlayersListLastMovement.keys(), [Player1.uuid], "Player 1 not in last movement")
	assert_eq(Server1.ServerMyPlayersListLastMovement[Player1.uuid], Vector3(0.0, 0.0, 0.0))

	assert_eq(Server1.PlayersListCurrentlyInTransfert.size(), 0, "Player 1 must not be in transfert mode")
	assert_eq(Server1.MQTTClientSDO.messages["sdo/playerschanges"].size(), 1, "Server 1 must send playerschanges message")
	assert_eq(
		Server1.MQTTClientSDO.messages["sdo/playerschanges"].get(0),
		JSON.stringify({
			"add": [{
				"name": Player1.name,
				"client_uuid": Player1.uuid,
				"x": 0.0,
				"y": 2.5,
				"z": 0.0
			}],
			"update": [],
			"delete": [],
			"server_id": 1,
		}),
		"Message of playerschanges not right"
	)

func test_start_server2():
	Server2._players_spawn_node = Server2.get_node("Players")

	var mqttGUT = preload("res://test/servermeshing/sdoInterface.tscn")
	Server2.MQTTClientSDO = mqttGUT.instantiate()
	# Server2.connect_mqtt_sdo()
	Server2._sdo_register()
	# check register
	assert_eq(Server2.MQTTClientSDO.messages["sdo/register"].size(), 1, "Server 1 must send registered message")
	assert_eq(
		Server2.MQTTClientSDO.messages["sdo/register"][0],
		JSON.stringify({"name": "gameserverDev0102", "ip": "192.168.0.10", "port": 7051}),
		"Message of register not right"
	)

func test_server2_receive_serverslist():
	Server2._on_mqtt_sdo_received_message(
		"sdo/serverslist",
		JSON.stringify([{
			"id": 1,
			"name": "gameserverDev0101",
			"ip": "192.168.0.10",
			"port": 7050,
			"x_start": -10000000,
			"x_end": 10000000,
			"y_start": -10000000,
			"y_end": 10000000,
			"z_start": -10000000,
			"z_end": 10000000,
			"to_merge_server_id": null
		}])
	)
	assert_eq(
		Server2.ServerZone,
		{
			"x_start": -100000,
			"x_end": 100000,
			"y_start": -100000,
			"y_end": 100000,
			"z_start": -100000,
			"z_end": 100000
		},
		"server zone not right"
	)
	assert_eq(Server2.ServerSDOId, 0, "ServerSDOId not activated")
	assert_false(Server2.isSDOActive, "isSDOActive must be false")
	assert_eq(
		Server2.ServerServersList,
		{
			1: {
				"id": 1,
				"name": "gameserverDev0101",
				"ip": "192.168.0.10",
				"port": 7050,
				"x_start": -10000000.0,
				"x_end": 10000000.0,
				"y_start": -10000000.0,
				"y_end": 10000000.0,
				"z_start": -10000000.0,
				"z_end": 10000000.0,
				"to_merge_server_id": null
			}
		}
	)
	assert_eq(Server2.MQTTClientSDO.subscribed, {"sdo/serverslist": true, "sdo/playerslist": true})

func test_server2_receive_playerslist():
	Server2._on_mqtt_sdo_received_message(
		"sdo/playerslist",
		JSON.stringify([
			{
				"name": Player1.name,
				"client_uuid": Player1.uuid,
				"server_id": 1,
				"x": 0.0,
				"y": 2.5,
				"z": 0.0
			}
		])
	)
	assert_eq(Server2.MQTTClientSDO.subscribed, {"sdo/serverslist": true, "sdo/playerslist": true})


func test_server1_player2_connect():
	Server1.MQTTClientSDO.messages["sdo/playerschanges"] = []
	Server1._on_player_connected(Player2.id)
	Server1.set_player_uuid(Player2.uuid, Player2.name, Player2.id)
	assert_eq(
		Server1.PlayersListTempById.keys(),
		[Player1.id, Player2.id]
	)
	assert_eq(
		Server1.ServerMyPlayersList.keys(),
		[Player1.uuid, Player2.uuid],
		"ServerMyPlayersList must have the 2 players"
	)
	assert_eq(Server1.ServersAllPlayersList.size(), 0, "ServersAllPlayersList must be empty")
	assert_eq(Server1.ServerMyPlayersListLastMovement.keys(), [Player1.uuid, Player2.uuid], "Player 1 and player 2 not in last movement")
	assert_eq(Server1.ServerMyPlayersListLastMovement[Player1.uuid], Vector3(0.0, 0.0, 0.0))
	assert_eq(Server1.ServerMyPlayersListLastMovement[Player2.uuid], Vector3(0.0, 0.0, 0.0))

	assert_eq(Server1.PlayersListCurrentlyInTransfert.size(), 0, "Players must not be in transfert mode")
	assert_eq(Server1.MQTTClientSDO.messages["sdo/playerschanges"].size(), 1, "Server 1 must send playerschanges message")
	assert_eq(
		Server1.MQTTClientSDO.messages["sdo/playerschanges"].get(0),
		JSON.stringify({
			"add": [{
				"name": Player2.name,
				"client_uuid": Player2.uuid,
				"x": 0.0,
				"y": 2.5,
				"z": 0.0
			}],
			"update": [],
			"delete": [],
			"server_id": 1,
		}),
		"Message of playerschanges not right"
	)

func test_server1_run_physics_process():
	# first to bypass the first playerschanges because will move at spawn
	await wait_frames(20)
	Server1.MQTTClientSDO.messages["sdo/playerschanges"] = []
	await wait_frames(20)
	# Test run the function _is_server_has_too_many_players
	assert_eq(Server1.MQTTClientSDO.messages["sdo/servertooheavy"].size(), 0, "No transfert planned")
	assert_false(Server1.ChangingZone)

	# Test run the function _send_players_to_sdo, not movements of players
	assert_eq(Server1.MQTTClientSDO.messages["sdo/playerschanges"].size(), 0)

	# Test run the function _checkPlayerOutOfZone
	assert_eq(Server1.PlayersListCurrentlyInTransfert.size(), 0)


func test_server_the_2_players_move():
	Server1.ServerMyPlayersList[Player1.uuid].set_global_position(
		Vector3(2145.0, 0.0, 15.67)
	)
	Server1.ServerMyPlayersList[Player2.uuid].set_global_position(
		Vector3(2151.57366, 0.0, 21.6784)
	)

	Server1.MQTTClientSDO.messages["sdo/playerschanges"] = []
	await wait_frames(20)

	# Test run the function _is_server_has_too_many_players
	assert_eq(Server1.MQTTClientSDO.messages["sdo/servertooheavy"].size(), 0, "No transfert planned")
	assert_false(Server1.ChangingZone)

	# Test run the function _send_players_to_sdo, not movements of players
	assert_eq(Server1.MQTTClientSDO.messages["sdo/playerschanges"].size(), 1)
	assert_eq(
		JSON.parse_string(Server1.MQTTClientSDO.messages["sdo/playerschanges"].get(0)),
		{
			"add": [],
			"delete": [],
			"server_id": 1.0,
			"update": [
				{
					"client_uuid": Player1.uuid,
					"x": 2145.0,
					"y": 0.0,
					"z": 15.67,
				},
				{
					"client_uuid": Player2.uuid,
					"x": 2151.57366,
					"y": 0.0,
					"z": 21.6784,
				}
			],
		}
	)

	# Test run the function _checkPlayerOutOfZone
	assert_eq(Server1.PlayersListCurrentlyInTransfert.size(), 0)



func test_server1_player3_connect():
	Server1.MQTTClientSDO.messages["sdo/playerschanges"] = []
	Server1._on_player_connected(Player3.id)
	Server1.set_player_uuid(Player3.uuid, Player3.name, Player3.id)
	assert_eq(
		Server1.PlayersListTempById.keys(),
		[Player1.id, Player2.id, Player3.id]
	)
	assert_eq(
		Server1.ServerMyPlayersList.keys(),
		[Player1.uuid, Player2.uuid, Player3.uuid],
		"ServerMyPlayersList must have the 3 players"
	)
	assert_eq(Server1.ServersAllPlayersList.size(), 0, "ServersAllPlayersList must be empty")
	assert_eq(Server1.ServerMyPlayersListLastMovement.keys(), [Player1.uuid, Player2.uuid, Player3.uuid], "The 3 players not in last movement")
	assert_eq(Server1.ServerMyPlayersListLastMovement[Player1.uuid], Vector3(2145.0, 0.0, 15.67))
	assert_eq(Server1.ServerMyPlayersListLastMovement[Player2.uuid], Vector3(2151.57366, 0.0, 21.6784))
	assert_eq(Server1.ServerMyPlayersListLastMovement[Player3.uuid], Vector3(0.0, 0.0, 0.0))

	assert_eq(Server1.PlayersListCurrentlyInTransfert.size(), 0, "Players must not be in transfert mode")
	assert_eq(Server1.MQTTClientSDO.messages["sdo/playerschanges"].size(), 1, "Server 1 must send playerschanges message")
	assert_eq(
		Server1.MQTTClientSDO.messages["sdo/playerschanges"].get(0),
		JSON.stringify({
			"add": [{
				"name": Player3.name,
				"client_uuid": Player3.uuid,
				"x": 0.0,
				"y": 2.5,
				"z": 0.0
			}],
			"update": [],
			"delete": [],
			"server_id": 1,
		}),
		"Message of playerschanges not right"
	)

func test_server1_player3_move():
	await wait_frames(300)
	assert_eq(Server1.MQTTClientSDO.messages["sdo/servertooheavy"].size(), 1, "Transfert must be planned")

	# check sdo/servertooheavy
	assert_eq(Server1.MQTTClientSDO.messages["sdo/servertooheavy"].size(), 1, "Server 1 must send servertooheavy message")
	assert_eq(
		Server1.MQTTClientSDO.messages["sdo/servertooheavy"].get(0),
		JSON.stringify({
			"id": 1,
			"players": [
				{
					"x": int(2145.0),
					"y": int(0.0),
					"z": int(15.67)
				},
				{
					"x": int(2151.57366),
					"y": int(0.0),
					"z": int(21.6784)
				},
				{
					"x": int(0.0),
					"y": int(2.5),
					"z": int(0.0)
				}
			]
		}),
		"Message of servertooheavy not right"
	)

func test_server1_receive_aftersplit():
	Server1.MQTTClientSDO.messages["sdo/servertooheavy"] = []
	Server1.MQTTClientSDO.messages["sdo/serverschanges"] = [JSON.stringify({
		"add": [
			{
				"id": 2,
				"name": "gameserverDev0102",
				"ip": "192.168.0.10",
				"port": 7051,
				"x_start": 1000.0,
				"x_end": 10000000.0,
				"y_start": -10000000.0,
				"y_end": 10000000.0,
				"z_start": -10000000.0,
				"z_end": 10000000.0,
				"to_split_server_id": null
			}
		],
		"update": [
			{
				"id": 1,
				"x_start": -10000000,
				"x_end": 1000,
				"y_start": -10000000,
				"y_end": 10000000,
				"z_start": -10000000,
				"z_end": 10000000,
				"to_split_server_id": 2
			}
		],
		"delete": []
	})]
	Server1._on_mqtt_sdo_received_message("sdo/serverschanges", Server1.MQTTClientSDO.messages["sdo/serverschanges"].get(0))
	assert_eq(Server1.ServerServersList.size(), 2, "We must have the 2 servers")

	assert_eq(
		Server1.ServerZone,
		{
			"x_start": -10000000.0,
			"x_end": 1000.0,
			"y_start": -10000000.0,
			"y_end": 10000000.0,
			"z_start": -10000000.0,
			"z_end": 10000000.0
		},
		"server zone not right"
	)

	assert_eq(Server1.PlayersListCurrentlyInTransfert.size(), 2, "Must have 2 players in transfert")
	assert_true(Server1.PlayersListCurrentlyInTransfert.has(Player1.uuid))
	assert_true(Server1.PlayersListCurrentlyInTransfert.has(Player2.uuid))

func test_server1_2_players_disconnect():
	Server1._on_player_disconnect(Player1.id)
	Server1._on_player_disconnect(Player2.id)
	# it's in transfert mode, must yet have the 3 players
	assert_eq(Server1.ServerMyPlayersList.size(), 3)


func test_server2_receive_serverslist_aftersplit():
	Server2.MQTTClientSDO.messages["sdo/serverslist"] = [JSON.stringify([
		{
			"id": 1,
			"name": "gameserverDev0101",
			"ip": "192.168.0.10",
			"port": 7050,
			"x_start": -10000000,
			"x_end": 1000,
			"y_start": -10000000,
			"y_end": 10000000,
			"z_start": -10000000,
			"z_end": 10000000,
			"to_merge_server_id": null
		},
		{
			"id": 2,
			"name": "gameserverDev0102",
			"ip": "192.168.0.10",
			"port": 7051,
			"x_start": 1000,
			"x_end": 10000000,
			"y_start": -10000000,
			"y_end": 10000000,
			"z_start": -10000000,
			"z_end": 10000000,
			"to_merge_server_id": null
		},
	])]
	Server2._on_mqtt_sdo_received_message("sdo/serverslist", Server2.MQTTClientSDO.messages["sdo/serverslist"].get(0))

	assert_eq(
		Server2.ServerZone,
		{
			"x_start": 1000.0,
			"x_end": 10000000.0,
			"y_start": -10000000.0,
			"y_end": 10000000.0,
			"z_start": -10000000.0,
			"z_end": 10000000.0
		},
		"server zone not right"
	)
	assert_eq(Server2.ServerSDOId, 2, "ServerSDOId must be set to 2")
	assert_true(Server2.isSDOActive, "isSDOActive must be true")
	assert_eq(
		Server2.ServerServersList,
		{
			1: {
				"id": 1,
				"name": "gameserverDev0101",
				"ip": "192.168.0.10",
				"port": 7050,
				"x_start": -10000000.0,
				"x_end": 1000.0,
				"y_start": -10000000.0,
				"y_end": 10000000.0,
				"z_start": -10000000.0,
				"z_end": 10000000.0,
				"to_merge_server_id": null
			},
			2: {
				"id": 2,
				"name": "gameserverDev0102",
				"ip": "192.168.0.10",
				"port": 7051,
				"x_start": 1000.0,
				"x_end": 10000000.0,
				"y_start": -10000000.0,
				"y_end": 10000000.0,
				"z_start": -10000000.0,
				"z_end": 10000000.0,
				"to_merge_server_id": null
			}
		}
	)
	assert_eq(Server2.MQTTClientSDO.subscribed, {"sdo/playerslist": true, "sdo/serverschanges": true})



func test_server2_receive_playerslist_aftersplit():
	Server2.MQTTClientSDO.messages["sdo/playerslist"] = [JSON.stringify([
		{
			"name": Player1.name,
			"client_uuid": Player1.uuid,
			"server_id": 1,
			"x": 2145.0,
			"y": 0.0,
			"z": 15.67,
		},
		{
			"name": Player2.name,
			"client_uuid": Player2.uuid,
			"server_id": 1,
			"x": 2151.57366,
			"y": 0.0,
			"z": 21.6784,
		},
		{
			"name": Player3.name,
			"client_uuid": Player3.uuid,
			"server_id": 1,
			"x": 0.0,
			"y": 2.5,
			"z": 0.0,
		},
	])]
	Server2._on_mqtt_sdo_received_message("sdo/playerslist", Server2.MQTTClientSDO.messages["sdo/playerslist"].get(0))
	await wait_frames(5)
	assert_eq(Server2.ServersAllPlayersList.size(), 3, "Must have the 3 remote players in server 2")
	assert_true(Server2.ServersAllPlayersList.has(Player1.uuid))
	assert_true(Server2.ServersAllPlayersList.has(Player2.uuid))
	assert_true(Server2.ServersAllPlayersList.has(Player3.uuid))
	# check global_position
	assert_eq(
		Server2.ServersAllPlayersList[Player1.uuid].get_global_position(),
		Vector3(2145.0, 0.0, 15.67)
	)
	assert_eq(
		Server2.ServersAllPlayersList[Player2.uuid].get_global_position(),
		Vector3(2151.57366, 0.0, 21.6784)
	)
	assert_eq(
		Server2.ServersAllPlayersList[Player3.uuid].get_global_position(),
		Vector3(0.0, 2.5, 0.0)
	)
	# check name
	assert_eq(
		Server2.ServersAllPlayersList[Player1.uuid].labelPlayerName.get_text(),
		Player1.name
	)
	assert_eq(
		Server2.ServersAllPlayersList[Player2.uuid].labelPlayerName.get_text(),
		Player2.name
	)
	assert_eq(
		Server2.ServersAllPlayersList[Player3.uuid].labelPlayerName.get_text(),
		Player3.name
	)
	# check labelservername
	assert_eq(
		Server2.ServersAllPlayersList[Player1.uuid].labelServerName.get_text(),
		"gameserverDev0101"
	)
	assert_eq(
		Server2.ServersAllPlayersList[Player2.uuid].labelServerName.get_text(),
		"gameserverDev0101"
	)
	assert_eq(
		Server2.ServersAllPlayersList[Player3.uuid].labelServerName.get_text(),
		"gameserverDev0101"
	)

func test_server2_player1_connect():
	Server2._on_player_connected(Player1.id)
	Server2.set_player_uuid(Player1.uuid, Player1.name, Player1.id)
	assert_eq(
		Server2.PlayersListTempById.keys(),
		[Player1.id]
	)
	assert_eq(
		Server2.ServerMyPlayersList.keys(),
		[Player1.uuid],
		"ServerMyPlayersList must have player"
	)
	assert_eq(Server2.ServersAllPlayersList.size(), 2, "ServersAllPlayersList must have 2 players")
	assert_eq(Server2.ServerMyPlayersListLastMovement.keys(), [Player1.uuid], "Player 1 not in last movement")
	assert_eq(Server2.ServerMyPlayersListLastMovement[Player1.uuid], Vector3(2145.0, 0.0, 15.67))

	assert_eq(Server2.PlayersListCurrentlyInTransfert.size(), 0, "Player 1 must not be in transfert mode")
	assert_eq(Server2.MQTTClientSDO.messages["sdo/playerschanges"].size(), 1, "Server 1 must send playerschanges message")
	assert_eq(
		Server2.MQTTClientSDO.messages["sdo/playerschanges"].get(0),
		JSON.stringify({
			"add": [],
			"delete": [],
			"server_id": 2,
			"update": [{
				"client_uuid": Player1.uuid,
				"x": 2145.0,
				"y": 0.0,
				"z": 15.67
			}],
		}),
		"Message of playerschanges not right"
	)

func test_server2_player2_connect():
	Server2.MQTTClientSDO.messages["sdo/playerschanges"] = []
	Server2._on_player_connected(Player2.id)
	Server2.set_player_uuid(Player2.uuid, Player2.name, Player2.id)
	assert_eq(
		Server2.PlayersListTempById.keys(),
		[Player1.id, Player2.id]
	)
	assert_eq(
		Server2.ServerMyPlayersList.keys(),
		[Player1.uuid, Player2.uuid],
		"ServerMyPlayersList must have player"
	)
	assert_eq(Server2.ServersAllPlayersList.size(), 1, "ServersAllPlayersList must have 1 players")
	assert_eq(Server2.ServerMyPlayersListLastMovement.keys(), [Player1.uuid, Player2.uuid], "Player 1 not in last movement")
	assert_eq(Server2.ServerMyPlayersListLastMovement[Player2.uuid], Vector3(2151.57366, 0.0, 21.6784))

	assert_eq(Server2.PlayersListCurrentlyInTransfert.size(), 0, "Player 2 must not be in transfert mode")
	assert_eq(Server2.MQTTClientSDO.messages["sdo/playerschanges"].size(), 1, "Server 2 must send playerschanges message")
	assert_eq(
		Server2.MQTTClientSDO.messages["sdo/playerschanges"].get(0),
		JSON.stringify({
			"add": [],
			"delete": [],
			"server_id": 2,
			"update": [{
				"client_uuid": Player2.uuid,
				"x": 2151.57366,
				"y": 0.0,
				"z": 21.6784
			}],
		}),
		"Message of playerschanges not right"
	)

func test_server1_receive_playerschanges_from_server2():
	Server1.MQTTClientSDO.messages["sdo/playerschanges"] = [
		JSON.stringify({
			"add": [],
			"delete": [],
			"server_id": 2,
			"update": [{
				"client_uuid": Player1.uuid,
				"x": 2145.0,
				"y": 0.0,
				"z": 15.67
			}],
		}),
		JSON.stringify({
			"add": [],
			"delete": [],
			"server_id": 2,
			"update": [{
				"client_uuid": Player2.uuid,
				"x": 2151.57366,
				"y": 0.0,
				"z": 21.6784
			}],
		}),
	]
	Server1._on_mqtt_sdo_received_message("sdo/playerschanges", Server1.MQTTClientSDO.messages["sdo/playerschanges"].get(0))
	Server1._on_mqtt_sdo_received_message("sdo/playerschanges", Server1.MQTTClientSDO.messages["sdo/playerschanges"].get(1))
	# Must not have this 2 uuid in ServerMyPlayersList
	assert_eq(Server1.ServerMyPlayersList.size(), 1, "Must have only the player 3 in ServerMyPlayersList")
	assert_true(Server1.ServerMyPlayersList.has(Player3.uuid))
	# Must have these 2 players uuid in ServersAllPlayersList
	assert_eq(Server1.ServersAllPlayersList.size(), 2, "Must have only the player 1 & 2 in ServersAllPlayersList")
	assert_true(Server1.ServersAllPlayersList.has(Player1.uuid))
	assert_true(Server1.ServersAllPlayersList.has(Player2.uuid))

func test_server1_global_positions():
	await wait_frames(60)
	assert_eq(
		Server1.ServersAllPlayersList[Player1.uuid].get_global_position(),
		Vector3(2145.0, 0.0, 15.67)
	)
	assert_eq(
		Server1.ServersAllPlayersList[Player2.uuid].get_global_position(),
		Vector3(2151.57366, 0.0, 21.6784)
	)
	assert_eq(
		Server1.ServerMyPlayersList[Player3.uuid].get_global_position(),
		Vector3(0.0, 2.5, 0.0)
	)

func test_server2_global_positions():
	assert_eq(
		Server2.ServerMyPlayersList[Player1.uuid].get_global_position(),
		Vector3(2145.0, 0.0, 15.67)
	)
	assert_eq(
		Server2.ServerMyPlayersList[Player2.uuid].get_global_position(),
		Vector3(2151.57366, 0.0, 21.6784)
	)
	assert_eq(
		Server2.ServersAllPlayersList[Player3.uuid].get_global_position(),
		Vector3(0.0, 2.5, 0.0)
	)

func test_server2_player1_move_check_server1():
	Server1.ServersAllPlayersList[Player1.uuid].set_global_position(Vector3(2153.0, 0.0, 14.66))
	await wait_frames(5)

	Server1.MQTTClientSDO.messages["sdo/playerschanges"] = [
		JSON.stringify({
			"add": [],
			"delete": [],
			"server_id": 2,
			"update": [{
				"client_uuid": Player1.uuid,
				"x": 2153.0,
				"y": 0.0,
				"z": 14.66
			}],
		}),
	]
	Server1._on_mqtt_sdo_received_message("sdo/playerschanges", Server1.MQTTClientSDO.messages["sdo/playerschanges"].get(0))
	await wait_frames(5)
	assert_eq(
		Server1.ServersAllPlayersList[Player1.uuid].get_global_position(),
		Vector3(2153.0, 0.0, 14.66)
	)	
