extends Node

func _debug_btn_pressed():
	print("debug button pressed")
	Wwise.post_event("test_bip_100ms", self)
