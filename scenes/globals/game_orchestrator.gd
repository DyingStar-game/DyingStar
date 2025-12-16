extends Node

enum ChangeStateReturns {OK, ERROR, NO_CHANGE}

enum NetworkRole {PLAYER, SERVER}
enum GameStates {HOME_MENU, UNIVERSE_MENU, GAME_MENU, PAUSE_MENU, PLAYING, SERVER_PLAYING, DEV, CONNEXION_ERROR}

const MAX_USERNAME_LENGTH: int = 32
const MIN_USERNAME_LENGTH: int = 4

const SCENE_TREE_EXTENDED_SCRIPT_PATH = preload("res://scenes/globals/scene_tree_extended.gd")

const GAME_STATES_SCENES_PATHS: Dictionary = {
	GameStates.HOME_MENU : "res://ui/login_page/login_page.tscn",
	GameStates.UNIVERSE_MENU : "res://ui/main_page/main_page.tscn",
	GameStates.GAME_MENU : "",
	GameStates.PAUSE_MENU : "",
	GameStates.PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GameStates.SERVER_PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GameStates.CONNEXION_ERROR : "res://ui/error_message/error_message.tscn",
	GameStates.DEV : "res://levels/devmode/dev_scene.tscn",
}

const SPAWN_POINTS_LIST: Array[Dictionary] = [
	{"label" : "Sandbox (planet 4) / surface", "point": 1, "node_path" : "PlanetA/PlanetTerrain/PlayerSpawnPointsList/PlayerSpawnPoint01"},
	{"label" : "Sandbox (planet 4) / space", "point": 2, "node_path" : "PlanetB/PlanetTerrain/PlayerSpawnPointsList/PlayerSpawnPoint01"},
	{"label" : "Moon 1 / planet 5 / surface", "point": 3, "node_path" : "StationA/PadGroup1/PlayerSpawnPointsList/PlayerSpawnPoint01"},
	{"label" : "Moon 1 / planet 5 / space", "point": 4, "node_path" : "StationB/PadGroup1/PlayerSpawnPointsList/PlayerSpawnPoint01"},
]

@export var levels: Array[PackedScene]

var current_network_role = null
var current_state = null
var distinguish_instances: Dictionary = {
	NetworkRole.PLAYER: {"instance_name": "Joueur", "instance_color": "salmon"},
	NetworkRole.SERVER: {"instance_name": "Serveur", "instance_color": "aquamarine"},
}

var login_player_name: String = "I am an idiot !" :
	set(receveid_name):
		if not receveid_name.strip_edges().is_empty() and receveid_name.length() >= MIN_USERNAME_LENGTH :
			login_player_name = receveid_name.left(MAX_USERNAME_LENGTH)
var requested_spawn_point: int = 0

func _enter_tree() -> void:
	get_tree().set_script(SCENE_TREE_EXTENDED_SCRIPT_PATH)

func _ready():
	if OS.has_feature("editor"):
		if ResourceUID.id_to_text(
			ResourceLoader.get_resource_uid(get_tree().current_scene.scene_file_path)
		) != ProjectSettings.get_setting("application/run/main_scene") and not OS.has_feature("dedicated_server"):
			return
		
		get_tree().connect("scene_changed_custom", _on_scene_changed)
		
		if OS.has_feature("dedicated_server"):
			var arguments = OS.get_cmdline_args()
			for argument in arguments:
				if argument.begins_with("--devmode="):
					var _dev_scene = argument.substr("--devmode=".length())
					
					change_network_role(NetworkRole.SERVER)
					change_game_state(GameStates.DEV)
					return
		else:
			if OS.has_feature("devmode"):
				
				change_network_role(NetworkRole.PLAYER)
				change_game_state(GameStates.DEV)
				return

	get_tree().connect("scene_changed_custom", _on_scene_changed)

	if OS.has_feature("dedicated_server"):
		change_network_role(NetworkRole.SERVER)
		change_game_state(GameStates.SERVER_PLAYING)
	else:
		change_network_role(NetworkRole.PLAYER)
		if OS.has_feature("devmode"):
			change_game_state(GameStates.PLAYING)
		else:
			change_game_state(GameStates.HOME_MENU)

func _notification(what):
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			## TODO :
			## TOUTES LES ACTIONS A FAIRE AVANT DE QUITTER (besoin d'envoyer l'info au serveur ?)
			get_tree().quit()

func is_server():
	return current_network_role == NetworkRole.SERVER

func change_network_role(new_network_role) -> int:
	match new_network_role:
		NetworkRole.PLAYER:
			current_network_role = new_network_role
			return ChangeStateReturns.OK
		NetworkRole.SERVER:
			current_network_role = new_network_role
			return ChangeStateReturns.OK
		_:
			return ChangeStateReturns.ERROR

func change_game_state(new_state) -> int:
	if new_state == current_state:
		return ChangeStateReturns.NO_CHANGE

	var return_state = ChangeStateReturns.OK

	match new_state:
		GameStates.HOME_MENU:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.HOME_MENU])
		GameStates.SERVER_PLAYING:
			current_state = new_state
			NetworkOrchestrator.create_server()
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.SERVER_PLAYING])
		GameStates.UNIVERSE_MENU:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.UNIVERSE_MENU])
		GameStates.CONNEXION_ERROR:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.CONNEXION_ERROR])
		GameStates.PLAYING:
			match current_state:
				GameStates.PAUSE_MENU:
					current_state = new_state
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_:
					if GameOrchestrator.GAME_STATES_SCENES_PATHS[GameOrchestrator.GameStates.PLAYING]:
						current_state = new_state
						NetworkOrchestrator.create_client()
						get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GameStates.PLAYING])
					else:
						printerr(error_string(ERR_FILE_BAD_PATH) + " (Aucune scène de jeu à ouvrir game_orchestrator.gd)")
						return_state = ChangeStateReturns.ERROR
		GameStates.PAUSE_MENU:
			match  current_state:
				GameStates.PLAYING:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
					current_state = new_state
				GameStates.DEV:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
					current_state = new_state
				_:
					return_state = ChangeStateReturns.NO_CHANGE
		GameStates.DEV:
			match current_network_role:
				GameOrchestrator.NetworkRole.SERVER:
					current_state = new_state
					NetworkOrchestrator.create_server()
					get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GameStates.DEV])
				GameOrchestrator.NetworkRole.PLAYER:
					current_state = new_state
					match current_state:
						GameStates.PAUSE_MENU:
							Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
						_:
							NetworkOrchestrator.create_client()
							get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GameStates.DEV])
				_:
					return_state = ChangeStateReturns.ERROR
		_:
			return_state = ChangeStateReturns.ERROR
	return return_state

func _on_scene_changed(changed_scene: Node) -> void:
	var scene_path: String = changed_scene.scene_file_path

	if scene_path == GAME_STATES_SCENES_PATHS[GameStates.PLAYING] or scene_path == GAME_STATES_SCENES_PATHS[GameStates.DEV]:
		
		match current_network_role:
			NetworkRole.SERVER:
				login_player_name = "AlfredThaddeusCranePennyworth"
				NetworkOrchestrator.start_server(changed_scene)
			NetworkRole.PLAYER:
				NetworkOrchestrator.start_client(changed_scene)
