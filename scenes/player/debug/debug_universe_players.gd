extends Label

func _ready() -> void:
	visible = false
	# Connected once, for the panel's whole life: the value is known the moment the panel is shown
	# (the F8 capture shows it for one frame), and hiding it no longer tries to disconnect a
	# callable that was never connected (nor showing it to connect the same one twice).
	NetworkOrchestrator.set_universe_players.connect(_set_universe_players)

func _set_universe_players(number_players):
	text = str(int(number_players)) + " players"

func _on_normal_player_display_debug(show: bool) -> void:
	visible = show
