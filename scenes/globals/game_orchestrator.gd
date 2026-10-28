extends Node

enum ChangeStateReturns {OK, ERROR, NO_CHANGE}

enum NetworkRole {PLAYER, SERVER}
enum GameStates {UNIVERSE_MENU, GAME_MENU, PAUSE_MENU, PLAYING, SERVER_UNIVERS_CREATION, SERVER_PLAYING, TROLL, CONNEXION_ERROR}
enum PlayingLevels {SYSTEM_SANDBOX}

const MAX_USERNAME_LENGTH: int = 32
const MIN_USERNAME_LENGTH: int = 4

const SCENE_TREE_EXTENDED_SCRIPT_PATH = preload("res://scenes/globals/scene_tree_extended.gd")

const GAME_STATES_SCENES_PATHS: Dictionary = {
	# The menu stands on a live 3D stage (Tarsis 3) with its UI on top; see MenuStage.
	GameStates.UNIVERSE_MENU : "res://levels/menu_stage/menu_stage.tscn",
	GameStates.GAME_MENU : "",
	GameStates.PAUSE_MENU : "",
	GameStates.PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GameStates.SERVER_UNIVERS_CREATION : "res://scenes/universe_creation/universe_map.tscn",
	GameStates.SERVER_PLAYING : "res://levels/system-sandbox/system_sandbox.tscn",
	GameStates.CONNEXION_ERROR : "res://ui/error_message/error_message.tscn",
}

const LOADING_SCENE: PackedScene = preload("res://ui/loading.tscn")
## The voice nodes (LiveKitAudio): quit_game leaves their rooms first. Named here and not in livekit.gd,
## which this autoload must never load: the dedicated server's export leaves the LiveKit extension out,
## so livekit.gd does not compile there.
const VOICE_GROUP := &"livekit_audio"
## Longest wait (s) for the voice room to be left before the game quits anyway.
const QUIT_VOICE_TIMEOUT_S := 1.0
## LiveKit's Rust library, kept loaded until the process dies (see tools/native/NativeLibraryPin.cs).
const VOICE_NATIVE_LIBRARY := "livekit_ffi.dll"
const NATIVE_LIBRARY_PIN_SCRIPT := "res://tools/native/NativeLibraryPin.cs"


var current_network_role = null
var current_state = null
var distinguish_instances: Dictionary = {
	NetworkRole.PLAYER: {"instance_name": "Joueur", "instance_color": "salmon"},
	NetworkRole.SERVER: {"instance_name": "Serveur", "instance_color": "aquamarine"},
}

var univers_creation_entities: Dictionary = {}

var connexion_error_message: String = ""

@onready var game_is_paused: bool = false
var _quitting: bool = false
## Voice rooms told to leave (LiveKitAudio.shutdown) that have not said they left yet: quit_game waits for
## them, so the room sees us go. That wait alone did not stop the crash at quit: LiveKit's threads outlive
## every room, and only pinning its library does (_pin_voice_library).
var voice_rooms_leaving: Array = []

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
	if Globals.is_stargrot_explorer():
		return
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
	# Closing the window goes through quit_game, which leaves the voice room before quitting.
	get_tree().auto_accept_quit = false

	if OS.has_feature("dedicated_server"):
		change_network_role(NetworkRole.SERVER)
		change_game_state(GameStates.SERVER_UNIVERS_CREATION)
	else:
		change_network_role(NetworkRole.PLAYER)
		_pin_voice_library()
		# With no player in the world yet, this is the menu music (see MusicDirector).
		MusicDirector.start()
		if OS.has_feature("devmode"):
			change_game_state(GameStates.PLAYING)
		else:
			var instance = LOADING_SCENE.instantiate()
			get_tree().root.add_child.call_deferred(instance)
			change_game_state(GameStates.UNIVERSE_MENU)

func _notification(what):
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			quit_game()


## Quit the game: leave the voice rooms first, waiting for them QUIT_VOICE_TIMEOUT_S at most, then quit
## (see voice_rooms_leaving). Every way out of the game comes here.
func quit_game() -> void:
	if _quitting:
		return
	_quitting = true
	for voice in get_tree().get_nodes_in_group(VOICE_GROUP):
		voice.shutdown()
	await voice_rooms_left(QUIT_VOICE_TIMEOUT_S)
	get_tree().quit()


## Keep LiveKit's library loaded until the process dies (Windows). Its threads start with the extension,
## before any room, and never stop; when Godot unloaded the library under them at exit, the first to wake
## ran code that was no longer there -- the client crashed on quit (crash dumps 2026-10-22, 2026-10-25).
func _pin_voice_library() -> void:
	if OS.get_name() != "Windows":
		return
	var script: Script = NativeScript.load_usable(NATIVE_LIBRARY_PIN_SCRIPT, ["Pin"])
	if script == null or not script.new().Pin(VOICE_NATIVE_LIBRARY):
		push_warning("[voice] %s not pinned: quitting may crash" % VOICE_NATIVE_LIBRARY)


## Wait until every voice room told to leave has left, or [param timeout_s] seconds at most (a room that
## never answers must not hold the game open).
func voice_rooms_left(timeout_s: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not voice_rooms_leaving.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

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
						# Deferred like the splash's own add_child above: a rebuilt one is not in the tree yet.
						LoadingSplash.show.call_deferred(get_tree(), "%%MENU_LOADING")
						LoadingSplash.progress.call_deferred(get_tree(), 0.05)
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
	LoadingSplash.progress(get_tree(), 0.3)
	get_tree().call_deferred("change_scene_to_file", GAME_STATES_SCENES_PATHS[GameStates.PLAYING])

func _on_scene_changed(changed_scene: Node) -> void:
	var scene_path: String = changed_scene.scene_file_path

	if scene_path == GAME_STATES_SCENES_PATHS[GameStates.PLAYING]:
		match current_network_role:
			NetworkRole.SERVER:
				var server_instance =  NetworkOrchestrator.start_server(changed_scene)
				server_instance.connect("populated_universe", _on_populated_universe)
			NetworkRole.PLAYER:
				# Every session starts on the server's clock. The +/- dev offset lives in an autoload, so
				# it outlived the session it was set in — and the menu stage hands back what it found.
				# Here the menu stage is already gone (it restores on leaving the tree).
				Globals.debug_time_offset = 0.0
				NetworkOrchestrator.start_client(changed_scene)
	elif scene_path == GAME_STATES_SCENES_PATHS[GameStates.SERVER_UNIVERS_CREATION]:
		changed_scene.connect("universe_data_retrieved", _on_universe_data_retrieved)
		changed_scene.retrieve_universe_datas()

func _on_universe_data_retrieved(datas: Dictionary) -> void:
	univers_creation_entities = datas
	change_game_state(GameStates.SERVER_PLAYING)

func _on_populated_universe(current_scene: Node) -> void:
	current_scene.assign_spawn_informations()
