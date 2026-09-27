extends RichTextLabel

func _ready() -> void:
	visible = false
	# Connected once, for the panel's whole life: the value is known the moment the panel is shown
	# (the F8 capture shows it for one frame), and hiding it no longer tries to disconnect a
	# callable that was never connected (nor showing it to connect the same one twice).
	NetworkOrchestrator.set_gameserver_server_tps.connect(_set_gameserver_server_tps)

func _set_gameserver_server_tps(tps):
	if tps >= 30:
		text = "[color=green]" + str(int(tps)) + "[/color] TPS"
	else:
		text = "[color=red]" + str(int(tps)) + "[/color] TPS"

func _on_normal_player_display_debug(show: bool) -> void:
	visible = show
