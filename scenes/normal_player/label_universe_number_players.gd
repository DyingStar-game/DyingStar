extends Label

func _ready() -> void:
	NetworkOrchestrator.set_gameserver_number_players_universe.connect(_set_gameserver_number_players_universe)

func _set_gameserver_number_players_universe(nb_players):
	text = str(nb_players)
