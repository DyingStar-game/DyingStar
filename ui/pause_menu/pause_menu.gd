extends Control

var actual_page: Control = null
## The full settings menu (general / graphics / audio / controls) — reused from the main menu.
var settings_scene: PackedScene = preload("res://ui/settings_page/settings_page.tscn")

@onready var main_pause_menu: Control = $PausePage
@onready var input_settings_menu: Control = $InputSettings

func _ready() -> void:
	main_pause_menu.settings_button.pressed.connect(
		_on_pause_menu_button_pressed.bind("settings_button")
	)
	main_pause_menu.quit_game_button.pressed.connect(
		_on_pause_menu_button_pressed.bind("quit_game_button")
	)
	main_pause_menu.return_menu_button.pressed.connect(
		_on_pause_menu_button_pressed.bind("return_menu_button")
	)
	main_pause_menu.resume_game_button.pressed.connect(
		_on_pause_menu_button_pressed.bind("resume_game_button")
	)

	input_settings_menu.return_main_menu_button.pressed.connect(
		_on_pause_menu_button_pressed.bind("return_main_menu_button")
	)

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority(): return

	if not visible:
		if event.is_action_pressed("pause"):
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PAUSE_MENU)
			visible = true
			main_pause_menu.visible = true
			actual_page = main_pause_menu
	else:
		if event.is_action_pressed("pause"):
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
			visible = false
			main_pause_menu.visible = false
			actual_page = null

		# Only "pause" (Esc) or the Resume button leaves the pause menu — a click in the void must not
		# resume the game (it used to un-pause on ANY mouse button).
		get_viewport().set_input_as_handled()

func _on_pause_menu_button_pressed(button_pressed: String) -> void:

	match  button_pressed:
		"settings_button":
			# Open the full settings menu (general/graphics/audio/controls) as an overlay; its own
			# Return button frees it and brings the pause menu back. DRY: same page as the main menu.
			add_child(settings_scene.instantiate())
		"quit_game_button":
			get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		"return_menu_button":
			NetworkOrchestrator.network_agent.disconnect_from_server()
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.UNIVERSE_MENU)
			visible = false
			main_pause_menu.visible = false
			actual_page = null
		"resume_game_button":
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
			visible = false
			main_pause_menu.visible = false
			actual_page = null
		"return_main_menu_button":
			actual_page.visible = false
			actual_page = main_pause_menu
			actual_page.visible = true
		_:
			pass
