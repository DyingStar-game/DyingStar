extends Node

enum ChangeStateReturns {OK, ERROR, NO_CHANGE}

enum NetworkRole {PLAYER, SERVER}
enum GameStates {UNIVERSE_MENU, GAME_MENU, PAUSE_MENU, PLAYING, SERVER_UNIVERS_CREATION, SERVER_PLAYING, TROLL, CONNEXION_ERROR}
enum PlayingLevels {SYSTEM_SANDBOX}

const MAX_USERNAME_LENGTH: int = 32
const MIN_USERNAME_LENGTH: int = 4

const SCENE_TREE_EXTENDED_SCRIPT_PATH = preload("res://scenes/globals/scene_tree_extended.gd")

const GAME_STATES_SCENES_PATHS: Dictionary = {
	GameStates.UNIVERSE_MENU : "res://ui/main_page/main_page.tscn",
	GameStates.GAME_MENU : "",
	GameStates.PAUSE_MENU : "",
	GameStates.PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GameStates.SERVER_UNIVERS_CREATION : "res://scenes/universe_creation/universe_map.tscn",
	GameStates.SERVER_PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GameStates.CONNEXION_ERROR : "res://ui/error_message/error_message.tscn",
}

const MENU_MUSIC_PATH: String = "res://assets/_universe/audio/music/DyingStart_testV1.mp3"
const MENU_MUSIC_FADE_OUT_SECONDS: float = 5.0

const LOADING_SCENE: PackedScene = preload("res://ui/loading.tscn")

@export var levels: Array[PackedScene]

var current_network_role = null
var current_state = null
var distinguish_instances: Dictionary = {
	NetworkRole.PLAYER: {"instance_name": "Joueur", "instance_color": "salmon"},
	NetworkRole.SERVER: {"instance_name": "Serveur", "instance_color": "aquamarine"},
}

var univers_creation_entities: Dictionary = {}

var connexion_error_message: String = ""

var _menu_music_player: AudioStreamPlayer = null
var _menu_music_fade_tween: Tween = null

@onready var game_is_paused: bool = false

func _enter_tree() -> void:
	# In editor mode, skip replacing the SceneTree script.
	# In headless non-server mode (e.g. GUT test runner), also skip it:
	# gut_cmdln.gd itself extends SceneTree and replacing its script mid-init
	# causes the engine to hang. Dedicated-server headless is excluded here
	# because it does need scene_tree_extended for change_scene_to_file.
	if OS.has_feature("editor"):
		return
	if DisplayServer.get_name() == "headless" and not OS.has_feature("dedicated_server"):
		return
	get_tree().set_script(SCENE_TREE_EXTENDED_SCRIPT_PATH)


func _ready():
	if OS.has_feature("editor"):
		var current := get_tree().current_scene
		if current == null:
			return
		if ResourceUID.id_to_text(
			ResourceLoader.get_resource_uid(current.scene_file_path)
		) != ProjectSettings.get_setting("application/run/main_scene") and not OS.has_feature("dedicated_server"):
			return
	# In headless non-server mode (GUT) we skipped set_script, so
	# scene_changed_custom does not exist. Nothing else to initialise either.
	if DisplayServer.get_name() == "headless" and not OS.has_feature("dedicated_server"):
		return

	get_tree().connect("scene_changed_custom", _on_scene_changed)

	if OS.has_feature("dedicated_server"):
		change_network_role(NetworkRole.SERVER)
		change_game_state(GameStates.SERVER_UNIVERS_CREATION)
	else:
		change_network_role(NetworkRole.PLAYER)
		menu_music()
		if OS.has_feature("devmode"):
			change_game_state(GameStates.PLAYING)
		else:
			var instance = LOADING_SCENE.instantiate()
			get_tree().root.add_child.call_deferred(instance)
			change_game_state(GameStates.UNIVERSE_MENU)

func menu_music() -> void:
	if _menu_music_fade_tween != null and _menu_music_fade_tween.is_valid():
		_menu_music_fade_tween.kill()
		_menu_music_fade_tween = null

	if _menu_music_player != null and is_instance_valid(_menu_music_player):
		_menu_music_player.volume_db = 0.0
		if not _menu_music_player.playing:
			_menu_music_player.play()
		return

	var stream: AudioStream = load(MENU_MUSIC_PATH)
	if stream == null:
		push_warning("menu_music: failed to load %s" % MENU_MUSIC_PATH)
		return

	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true

	_menu_music_player = AudioStreamPlayer.new()
	_menu_music_player.name = "MenuMusicPlayer"
	_menu_music_player.stream = stream
	_menu_music_player.bus = "Music"  # so the Audio settings Music slider controls it
	_menu_music_player.autoplay = false
	_menu_music_player.volume_db = 0.0
	add_child(_menu_music_player)
	_menu_music_player.play()

func stop_menu_music(fade_seconds: float = MENU_MUSIC_FADE_OUT_SECONDS) -> void:
	if _menu_music_player == null or not is_instance_valid(_menu_music_player):
		return

	if _menu_music_fade_tween != null and _menu_music_fade_tween.is_valid():
		_menu_music_fade_tween.kill()
		_menu_music_fade_tween = null

	var player := _menu_music_player
	# Detach the reference now so a subsequent menu_music() call creates a fresh player
	# instead of resurrecting the one being faded out.
	_menu_music_player = null

	if fade_seconds <= 0.0:
		player.stop()
		player.queue_free()
		return

	_menu_music_fade_tween = create_tween()
	_menu_music_fade_tween.tween_property(player, "volume_db", -80.0, fade_seconds)
	_menu_music_fade_tween.tween_callback(Callable(player, "stop"))
	_menu_music_fade_tween.tween_callback(Callable(player, "queue_free"))

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
		GameStates.SERVER_UNIVERS_CREATION:
			current_state = new_state
			NetworkOrchestrator.create_server()
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.SERVER_UNIVERS_CREATION])
		GameStates.SERVER_PLAYING:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.SERVER_PLAYING])
		GameStates.UNIVERSE_MENU:
			current_state = new_state
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.UNIVERSE_MENU])
		GameStates.CONNEXION_ERROR:
			current_state = new_state
			# The loading splash is a CanvasLayer at layer 100 living on the root, and it is normally
			# removed by the player once it spawns. On this path no player will ever spawn, so it would
			# stay on top of the error dialog and the user would only ever see an eternal "loading".
			_remove_loading_splash()
			get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.CONNEXION_ERROR])
		GameStates.PLAYING:
			match current_state:
				GameStates.PAUSE_MENU:
					current_state = new_state
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_:
					if GameOrchestrator.GAME_STATES_SCENES_PATHS[GameOrchestrator.GameStates.PLAYING]:
						current_state = new_state
						# The splash is created once at startup, but a failed session frees it (see
						# _remove_loading_splash). Rebuild it here so a second attempt is covered too.
						var loading_node: Node = get_tree().root.get_node_or_null("Loading")
						if loading_node == null:
							loading_node = LOADING_SCENE.instantiate()
							get_tree().root.add_child.call_deferred(loading_node)
						var loading_screen: Node = loading_node.get_node_or_null("LoadingScreen")
						if loading_screen:
							loading_screen.visible = true
						# create_client() blocks the main thread for a few seconds, so run it (and the
						# scene change) only after the splash has actually painted one frame.
						_start_playing_deferred()
					else:
						printerr(error_string(ERR_FILE_BAD_PATH) + " (Aucune scène de jeu à ouvrir game_orchestrator.gd)")
						return_state = ChangeStateReturns.ERROR
		GameStates.PAUSE_MENU:
			match  current_state:
				GameStates.PLAYING:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
					current_state = new_state
				_:
					return_state = ChangeStateReturns.NO_CHANGE
		_:
			return_state = ChangeStateReturns.ERROR
	return return_state

## Drop the loading splash if it is still up. Safe to call when there is none.
func _remove_loading_splash() -> void:
	var loading_node: Node = get_tree().root.get_node_or_null("Loading")
	if loading_node != null:
		loading_node.queue_free()


## Wait for the loading splash to paint one frame, then run the blocking client creation and swap
## to the PLAYING scene. Kept separate so change_game_state() stays synchronous (returns its int).
func _start_playing_deferred() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	NetworkOrchestrator.create_client()
	get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.PLAYING])

func _on_scene_changed(changed_scene: Node) -> void:
	var scene_path: String = changed_scene.scene_file_path

	if scene_path == GAME_STATES_SCENES_PATHS[GameStates.PLAYING]:
		match current_network_role:
			NetworkRole.SERVER:
				var server_instance =  NetworkOrchestrator.start_server(changed_scene)
				server_instance.connect("populated_universe", _on_populated_universe)
			NetworkRole.PLAYER:
				NetworkOrchestrator.start_client(changed_scene)
	elif scene_path == GAME_STATES_SCENES_PATHS[GameStates.SERVER_UNIVERS_CREATION]:
		changed_scene.connect("universe_data_retrieved", _on_universe_data_retrieved)
		changed_scene.retrieve_universe_datas()

func _on_universe_data_retrieved(datas: Dictionary) -> void:
	univers_creation_entities = datas
	change_game_state(GameStates.SERVER_PLAYING)

func _on_populated_universe(current_scene: Node) -> void:
	current_scene.assign_spawn_informations()
