extends Control

const REGEX_ALLOWED_CHARS = "[^a-zA-Z0-9- _éèàçùâêîôûäëïöüÿ]"
const REGEX_MULTIPLE_SPACES = " {2,}"

@onready var username_edit: LineEdit = $FormPlacer/FormContainer/UserName

var is_ready: bool = false

var allowed_chars_filter: RegEx = RegEx.new()
var multiples_spaces_filter: RegEx = RegEx.new()

func _on_ready() -> void:
	is_ready = true
	
	allowed_chars_filter.compile(REGEX_ALLOWED_CHARS)
	multiples_spaces_filter.compile(REGEX_MULTIPLE_SPACES)
	
	username_edit.connect("text_changed", _on_username_changed)

func _on_button_pressed(button_id: String) -> void:
	# TODO Call HTTP request to auth server to authenticate
	if username_edit.get_text():
		GameOrchestrator.login_player_name = username_edit.get_text()
	match button_id:
		"Online":
			Globals.onlineMode = true
			GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.UNIVERSE_MENU)
		"Local":
			Globals.onlineMode = false
			GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.TROLL)

func _on_username_changed(new_username: String) -> void:
	var cursor_pos = username_edit.caret_column
	var cleaned_name: String = ""
	
	if new_username.length() > 0:
		cleaned_name = allowed_chars_filter.sub(new_username, "", true)
		cleaned_name = multiples_spaces_filter.sub(cleaned_name, " ", true)
	
	if username_edit.text != cleaned_name:
		username_edit.text = cleaned_name
		username_edit.caret_column = cursor_pos
