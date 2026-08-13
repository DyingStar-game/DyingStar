extends Label

func _ready() -> void:
	visible = false

func _on_normal_player_display_debug(show: bool) -> void:
	if show:
		visible = true
		while visible:
			await get_tree().create_timer(1.0).timeout
			# This polls every second for as long as the panel is up, so it also runs while there is
			# no network agent (before connecting, and once the session is released on the way back
			# to the menu). Without the guard it spams "Invalid access ... on a base object of Nil".
			var agent = NetworkOrchestrator.network_agent
			if agent == null or not "players_list" in agent:
				text = "- players"
				continue
			text = str(agent.players_list.size()) + " players"
	else:
		visible = false
