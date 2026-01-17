extends Label

func _ready() -> void:
	visible = false

func _set_universe_players(number_players):
	text = str(int(number_players)) + " players"

func _disconnect():
	pass

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		NetworkOrchestrator.set_universe_players.connect(_set_universe_players)
	else:
		visible = false
		NetworkOrchestrator.set_universe_players.disconnect(_disconnect)
