extends Node

@export var levels: Array[PackedScene]

const MAX_USERNAME_LENGTH: int = 32
const MIN_USERNAME_LENGTH: int = 4

enum CHANGE_STATE_RETURNS {OK, ERROR, NO_CHANGE}

enum NETWORK_ROLE {PLAYER, SERVER}
enum GAME_STATES {HOME_MENU, UNIVERSE_MENU, GAME_MENU, PAUSE_MENU, PLAYING, SERVER_UNIVERS_CREATION, SERVER_PLAYING, TROLL, CONNEXION_ERROR}
enum PLAYING_LEVELS{SYSTEM_SANDBOX}

const SCENE_TREE_EXTENDED_SCRIPT_PATH = preload("res://scenes/globals/scene_tree_extended.gd")

const GAME_STATES_SCENES_PATHS: Dictionary = {
	GAME_STATES.HOME_MENU : "res://ui/login_page/login_page.tscn",
	GAME_STATES.UNIVERSE_MENU : "res://ui/main_page/main_page.tscn",
	GAME_STATES.GAME_MENU : "",
	GAME_STATES.PAUSE_MENU : "",
	GAME_STATES.PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GAME_STATES.SERVER_UNIVERS_CREATION : "res://scenes/universe_creation/universe_map.tscn",
	GAME_STATES.SERVER_PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GAME_STATES.TROLL : "res://ui/trolling_page/trolling_page.tscn",
	GAME_STATES.CONNEXION_ERROR : "res://ui/error_message/error_message.tscn",
}

var current_network_role = null
var current_state = null
var distinguish_instances: Dictionary = {
		NETWORK_ROLE.PLAYER: {"instance_name": "Joueur", "instance_color": "salmon"},
		NETWORK_ROLE.SERVER: {"instance_name": "Serveur", "instance_color": "aquamarine"},
	}

const SPAWN_POINTS_LIST: Array[Dictionary] = [
	{"label" : "PlanetA / SpawnPoint1", "node_path" : "PlanetA/PlanetTerrain/PlayerSpawnPointsList/PlayerSpawnPoint01"},
	{"label" : "PlanetB / SpawnPoint1", "node_path" : "PlanetB/PlanetTerrain/PlayerSpawnPointsList/PlayerSpawnPoint01"},
	{"label" : "StationA / SpawnPoint1", "node_path" : "StationA/PadGroup1/PlayerSpawnPointsList/PlayerSpawnPoint01"},
	{"label" : "StationB / SpawnPoint1", "node_path" : "StationB/PadGroup1/PlayerSpawnPointsList/PlayerSpawnPoint01"},
]

var univers_creation_entities: Dictionary = {}

var login_player_name: String = "I am an idiot !" :
	set(receveid_name):
		if not receveid_name.strip_edges().is_empty() and receveid_name.length() >= MIN_USERNAME_LENGTH :
			login_player_name = receveid_name.left(MAX_USERNAME_LENGTH)
var requested_spawn_point: int = 0

@onready var game_is_paused: bool = false

func _enter_tree() -> void:
	get_tree().set_script(SCENE_TREE_EXTENDED_SCRIPT_PATH)

func _ready():
	if OS.has_feature("editor"):
		if ResourceUID.id_to_text(ResourceLoader.get_resource_uid(get_tree().current_scene.scene_file_path)) != ProjectSettings.get_setting("application/run/main_scene") and not OS.has_feature("dedicated_server"):
			return
	
	get_tree().connect("scene_changed",_on_scene_changed)
	
	if OS.has_feature("dedicated_server"):
		change_network_role(NETWORK_ROLE.SERVER)
		change_game_state(GAME_STATES.SERVER_UNIVERS_CREATION)
	else:
		change_network_role(NETWORK_ROLE.PLAYER)
		change_game_state(GAME_STATES.HOME_MENU)

func change_network_role(new_network_role) -> int:
	match new_network_role:
		NETWORK_ROLE.PLAYER:
			current_network_role = new_network_role
			return CHANGE_STATE_RETURNS.OK
		NETWORK_ROLE.SERVER:
			current_network_role = new_network_role
			return CHANGE_STATE_RETURNS.OK
		_:
			return CHANGE_STATE_RETURNS.ERROR

func change_game_state(new_state) -> int:
	if new_state == current_state:
		return CHANGE_STATE_RETURNS.NO_CHANGE
	
	match new_state:
		GAME_STATES.TROLL:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GAME_STATES.TROLL])
			return CHANGE_STATE_RETURNS.OK
		GAME_STATES.HOME_MENU:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GAME_STATES.HOME_MENU])
			return CHANGE_STATE_RETURNS.OK
		GAME_STATES.SERVER_UNIVERS_CREATION:
			current_state = new_state
			NetworkOrchestrator.create_server()
			get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GAME_STATES.SERVER_UNIVERS_CREATION])
			return CHANGE_STATE_RETURNS.OK
		GAME_STATES.SERVER_PLAYING:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GAME_STATES.SERVER_PLAYING])
			return CHANGE_STATE_RETURNS.OK
		GAME_STATES.UNIVERSE_MENU:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GAME_STATES.UNIVERSE_MENU])
			return CHANGE_STATE_RETURNS.OK
		GAME_STATES.PLAYING:
			match current_state:
				GAME_STATES.PAUSE_MENU:
					current_state = new_state
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
					return CHANGE_STATE_RETURNS.OK
				_:
					if GameOrchestrator.GAME_STATES_SCENES_PATHS[GameOrchestrator.GAME_STATES.PLAYING]:
						current_state = new_state
						NetworkOrchestrator.create_client()
						get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GAME_STATES.PLAYING])
						return CHANGE_STATE_RETURNS.OK
					else:
						printerr(error_string(ERR_FILE_BAD_PATH) + " (Aucune scène de jeu à ouvrir game_orchestrator.gd)")
						return CHANGE_STATE_RETURNS.ERROR
		GAME_STATES.PAUSE_MENU:
			match  current_state:
				GAME_STATES.PLAYING:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
					current_state = new_state
					return CHANGE_STATE_RETURNS.OK
				_:
					return CHANGE_STATE_RETURNS.NO_CHANGE
		GAME_STATES.CONNEXION_ERROR:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file",GAME_STATES_SCENES_PATHS[GAME_STATES.CONNEXION_ERROR])
			return CHANGE_STATE_RETURNS.OK
		_:
			return CHANGE_STATE_RETURNS.ERROR

func _on_scene_changed(changed_scene: Node) -> void:
	var scene_path: String = changed_scene.scene_file_path
	
	match scene_path:
		GAME_STATES_SCENES_PATHS[GAME_STATES.PLAYING]:
			match current_network_role:
				NETWORK_ROLE.SERVER:
					login_player_name = "AlfredThaddeusCranePennyworth"
					var server_instance =  NetworkOrchestrator.start_server(changed_scene)
					server_instance.connect("populated_universe", _on_populated_universe)
					# server_instance.populate_universe(univers_creation_entities)
				NETWORK_ROLE.PLAYER:
					NetworkOrchestrator.start_client(changed_scene)
		GAME_STATES_SCENES_PATHS[GAME_STATES.SERVER_UNIVERS_CREATION]:
			changed_scene.connect("universe_data_retrieved", _on_universe_data_retrieved)
			changed_scene.retrieve_universe_datas()
		_:
			pass

func _on_universe_data_retrieved(datas: Dictionary) -> void:
	univers_creation_entities = datas
	change_game_state(GAME_STATES.SERVER_PLAYING)

func _on_populated_universe(current_scene: Node) -> void:
	current_scene.assign_spawn_informations()
