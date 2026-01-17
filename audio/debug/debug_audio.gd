extends Node

func _debug_btn_pressed():
	print("debug button pressed")
	Wwise.post_event("test_bip_100ms", self)

func _start_music():
	Wwise.post_event("play_bgm", self)

func _change_to_sandbox():
	Wwise.set_state("background_music", "sandbox")

func _change_to_menu():
	Wwise.set_state("background_music", "menu")

func _change_to_none():
	Wwise.set_state("background_music", "None")
