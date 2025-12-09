extends Label

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			var number_players = NetworkOrchestrator.network_agent.players_list.size()
			text = str(int(number_players)) + " players"
	else:
		visible = false
