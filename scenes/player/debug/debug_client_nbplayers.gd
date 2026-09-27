extends Label

var _poll: Timer = null

func _ready() -> void:
	_poll = DebugPoll.attach(self, 1.0, _refresh)

func _on_normal_player_display_debug(show: bool) -> void:
	DebugPoll.set_shown(self, _poll, show, _refresh)

func _refresh() -> void:
	# This polls every second for as long as the panel is up, so it also runs while there is
	# no network agent (before connecting, and once the session is released on the way back
	# to the menu). Without the guard it spams "Invalid access ... on a base object of Nil".
	var agent = NetworkOrchestrator.network_agent
	if agent == null or not "players_list" in agent:
		text = "- players"
		return
	text = str(agent.players_list.size()) + " players"
