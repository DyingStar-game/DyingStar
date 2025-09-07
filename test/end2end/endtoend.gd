extends Node
# code for end2end tests
# this code is used to drive and connect headleass players to server to test.

var player_name: String = "unknown"
var rand = RandomNumberGenerator.new()
var last: String = ""
var tick: int = 102

func _ready() -> void:
	for argument in OS.get_cmdline_args():
		if argument.contains("pname="):
			var key_value = argument.split("=")
			player_name = key_value[1]

	if player_name != "unknown":
		# we set pseudo and enter
		GameOrchestrator.login_player_name = player_name
		Globals.onlineMode = true
		GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.UNIVERSE_MENU)

		GameOrchestrator.requested_spawn_point = 2
		GameOrchestrator.change_game_state(GameOrchestrator.GAME_STATES.PLAYING)

		Input.action_press("move_forward");
		last = "move_forward"


func _physics_process(_delta: float) -> void:
	if player_name != "unknown":
		if tick > 0:
			tick -= 1
		else:
			var num = rand.randf()
			if num < 0.1:
				if last != "move_back":
					Input.action_release(last)
				else:
					return
				Input.action_press("move_back");
				last = "move_back"
			elif num < 0.2:
				if last != "move_left":
					Input.action_release(last)
				else:
					return
				Input.action_press("move_left");
				last = "move_left"
			elif num < 0.4:
				if last != "move_right":
					Input.action_release(last)
				else:
					return
				Input.action_press("move_right");
				last = "move_right"
			else:
				if last != "move_forward":
					Input.action_release(last)
				else:
					return
				Input.action_press("move_forward");
				last = "move_forward"
			tick = 102

