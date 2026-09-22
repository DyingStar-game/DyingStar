extends RichTextLabel

func _ready() -> void:
	visible = false

func _set_gameserver_server_tps(tps):
	if tps >= 30:
		text = "[color=green]" + str(int(tps)) + "[/color] TPS"
	else:
		text = "[color=red]" + str(int(tps)) + "[/color] TPS"

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_gameserver_server_tps.connect(_set_gameserver_server_tps)
	else:
		visible = false
		NetworkOrchestrator.set_gameserver_server_tps.disconnect(_disconnect)
