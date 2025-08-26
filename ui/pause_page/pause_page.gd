extends Control

@onready var keymapping_button: Button = $MarginContainer/VBoxContainer/KeymappingButton
@onready var quit_game_button: Button = $MarginContainer/VBoxContainer/QuitGameButton
@onready var resume_game_button: Button = $MarginContainer/VBoxContainer/ResumeGameButton

func _ready() -> void:
	pass
	#keymapping_button.pressed.connect(_on_pause_menu_button_pressed.bind(keymapping_button))
	#quit_game_button.pressed.connect(_on_pause_menu_button_pressed.bind(quit_game_button))
	#resume_game_button.pressed.connect(_on_pause_menu_button_pressed.bind(resume_game_button))

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority(): return
	
	#if not visible:
		#if event.is_action_pressed("pause"):
			#GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PAUSE_MENU)
			#visible = true
	#else:
		#if event.is_action_pressed("pause"):
			#GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PLAYING)
			#visible = false
		#
		#if event is InputEventMouseButton:
			#GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PLAYING)
			#visible = false
		#
		#get_viewport().set_input_as_handled()
