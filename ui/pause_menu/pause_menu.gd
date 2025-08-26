extends Control

@onready var main_pause_menu: Control = $PausePage
@onready var input_settings_menu: Control = $InputSettings

var actual_page: Control = null

func _ready() -> void:
	main_pause_menu.keymapping_button.pressed.connect(_on_pause_menu_button_pressed.bind("keymapping_button"))
	main_pause_menu.quit_game_button.pressed.connect(_on_pause_menu_button_pressed.bind("quit_game_button"))
	main_pause_menu.resume_game_button.pressed.connect(_on_pause_menu_button_pressed.bind("resume_game_button"))
	
	input_settings_menu.return_main_menu_button.pressed.connect(_on_pause_menu_button_pressed.bind("return_main_menu_button"))

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority(): return
	
	if not visible:
		if event.is_action_pressed("pause"):
			GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PAUSE_MENU)
			visible = true
			main_pause_menu.visible = true
			actual_page = main_pause_menu
	else:
		if event.is_action_pressed("pause"):
			GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PLAYING)
			visible = false
			main_pause_menu.visible = false
			actual_page = null
		
		if event is InputEventMouseButton and actual_page == main_pause_menu:
			GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PLAYING)
			visible = false
		
		get_viewport().set_input_as_handled()

func _on_pause_menu_button_pressed(button_pressed: String) -> void:
	
	match  button_pressed:
		"keymapping_button":
			actual_page.visible = false
			actual_page = input_settings_menu
			actual_page.visible = true
		"quit_game_button":
			pass
		"resume_game_button":
			GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PLAYING)
			visible = false
			main_pause_menu.visible = false
			actual_page = null
		"return_main_menu_button":
			actual_page.visible = false
			actual_page = main_pause_menu
			actual_page.visible = true
		_:
			pass
