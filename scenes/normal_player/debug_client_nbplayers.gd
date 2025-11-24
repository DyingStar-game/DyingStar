extends Label

func _ready() -> void:
	while true:
		await get_tree().create_timer(1.0).timeout
		var number_players = NetworkOrchestrator.network_agent.players_list.size()
		text = str(int(number_players)) + " players"
